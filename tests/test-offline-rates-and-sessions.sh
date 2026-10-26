#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Offline checks (no cluster needed) for two behaviours that must not regress:
#   1. rates given to tc keep their precision (kbit, never rounded to 0 Mbit/s)
#   2. the band throughput model (Shannon) gives the expected rate per band
#   3. tools/recover-ue-sessions.sh never says ALL_HEALTHY while a session is
#      unverified, and only restarts UEs whose ping fails.
# kubectl is replaced by a small fake, so the scripts run exactly as on the lab.
# Usage  : bash tests/test-offline-rates-and-sessions.sh
# Output : VERDICT=OFFLINE_CHECKS_PASS or VERDICT=OFFLINE_CHECKS_FAIL
# ---------------------------------------------------------------------------
set -u
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0
check() { # <label> <expected> <got>
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; FAIL=1; fi
}

# --- 1. rate computation -----------------------------------------------------
source "$REPO/scripts/ue/ue-common.sh"
check "embb 100% of 35 Mbit"   "35000kbit" "$(rate_kbit 100 35)"
check "urllc 3% of 35 Mbit"    "1050kbit"  "$(rate_kbit 3 35)"
check "mmtc 0.1% of 35 Mbit"   "35kbit"    "$(rate_kbit 0.1 35)"
check "never zero (0.1% of 1)" "1kbit"     "$(rate_kbit 0.1 1)"
check "fspl n78 55% of 35"     "19250kbit" "$(rate_kbit 55 35)"
check "tc text Kbit -> kbit"   "1050"      "$(tc_rate_to_kbit 1050Kbit)"
check "tc text Mbit -> kbit"   "35000"     "$(tc_rate_to_kbit 35Mbit)"

# --- 2. UE session diagnosis with a fake cluster ----------------------------
mkdir -p "$TMP/repo/scripts/ue" "$TMP/bin"
cat > "$TMP/repo/scripts/ue/ue-common.sh" <<'STUB'
ue_pod_for_deployment() { echo "pod-$2"; }
ue_tunnel_ip_for_pod() { case "$2" in pod-oai-nr-ue) n=1;; *) n="${2##*-}";; esac; echo "${FAKE_TUN_PREFIX:-10.45.0.}$n/24"; }
wait_exact_ue_tunnel() { echo "pod-$2|10.45.0.77"; }
STUB
cat > "$TMP/bin/kubectl" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"get cm"*)  n="${args#*oai-nrue-config}"; n="${n%% *}"; n="${n:-1}"
               echo "uicc0 = { imsi = \"00101000000000${n#-}\"; }" ;;
  *logs*)      [ "${FAKE_NO_SMF_LOG:-0}" = 1 ] && exit 0
               for i in 1 2 3 4 5; do echo "imsi-00101000000000$i IPv4[10.45.0.$i]"; done ;;
  *ping*)      case "$args" in *"pod-oai-nr-ue-5"*) [ "${FAKE_PING_FAIL:-0}" = 1 ] && echo "3 packets, 100% packet loss" && exit 0;; esac
               echo "3 packets, 0% packet loss" ;;
  *rollout*)   echo "RESTARTED $args" ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"
run() { PATH="$TMP/bin:$PATH" REPO="$TMP/repo" bash "$REPO/tools/recover-ue-sessions.sh" "$@" 2>&1; }

# Fake UE n has tunnel IP 10.45.0.n, which is also what the fake SMF log says.
out="$(run)"
echo "$out" | grep -q "VERDICT=ALL_HEALTHY" && r=yes || r=no
check "all matching + ping ok -> ALL_HEALTHY" yes "$r"

out="$(FAKE_TUN_PREFIX=10.45.9. run)"
echo "$out" | grep -q "VERDICT=ALL_HEALTHY" && r=yes || r=no
check "ip mismatch with ping ok -> no ALL_HEALTHY" no "$r"
echo "$out" | grep -q "CHECK(ip-mismatch,ping-ok)" && r=yes || r=no
check "ip mismatch is reported as CHECK" yes "$r"

out="$(FAKE_NO_SMF_LOG=1 run)"
echo "$out" | grep -q "VERDICT=ALL_HEALTHY" && r=yes || r=no
check "SMF log missing -> no ALL_HEALTHY" no "$r"
echo "$out" | grep -q "UNKNOWN" && r=yes || r=no
check "SMF log missing is reported as UNKNOWN" yes "$r"

out="$(FAKE_PING_FAIL=1 run --fix --yes)"
check "only the failing UE is restarted" "1" "$(echo "$out" | grep -c 'RESTARTED')"
echo "$out" | grep -q "rollout restart oai-nr-ue-5" && r=yes || r=no
check "restarted UE is the failing one" yes "$r"

# --- 3. band model through apply-fspl-band-profile.sh (fake kubectl, ceiling 35) ---
cat > "$TMP/repo/scripts/ue/ue-common.sh" <<STUB
source "$REPO/scripts/ue/ue-common.sh"
ue_pod_for_deployment() { echo "pod-ue"; }
STUB
band_line() { PATH="$TMP/bin:$PATH" REPO="$TMP/repo" CEILING_MBIT=35 HOME="$TMP" \
  bash "$REPO/scripts/frequency/apply-fspl-band-profile.sh" "$1" 2>&1 | grep -m1 "^f_ref="; }
check "band n41 (reference)" "dPL=0.00dB  K=1.00  PCT=100%" "$(band_line n41 | sed 's/.*dPL=/dPL=/')"
check "band n78 (K 0.87)"    "dPL=2.60dB  K=0.87  PCT=87%"  "$(band_line n78 | sed 's/.*dPL=/dPL=/')"
check "band n77 (K 0.80)"    "dPL=4.13dB  K=0.80  PCT=80%"  "$(band_line n77 | sed 's/.*dPL=/dPL=/')"
rate_of() { PATH="$TMP/bin:$PATH" REPO="$TMP/repo" CEILING_MBIT=35 HOME="$TMP" \
  bash "$REPO/scripts/frequency/apply-fspl-band-profile.sh" "$1" 2>&1 | grep -m1 -o "rate=[0-9]*kbit"; }
check "rate n78 = 87% of 35 Mbit" "rate=30450kbit" "$(rate_of n78)"
check "rate n77 = 80% of 35 Mbit" "rate=28000kbit" "$(rate_of n77)"
check "bad SNR_REF is refused" "VERDICT=BAD_SNR_REF" \
  "$(PATH="$TMP/bin:$PATH" REPO="$TMP/repo" SNR_REF=abc HOME="$TMP" bash "$REPO/scripts/frequency/apply-fspl-band-profile.sh" n78 2>&1 | grep -o 'VERDICT=[A-Z_]*')"

if [ "$FAIL" = 0 ]; then echo "VERDICT=OFFLINE_CHECKS_PASS"; else echo "VERDICT=OFFLINE_CHECKS_FAIL"; exit 1; fi
