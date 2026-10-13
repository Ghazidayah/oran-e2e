#!/usr/bin/env bash
# Read-only check of the Multi-UE UDP scenario outside the dashboard.
#   tools/diagnose-udp-multi-ue.sh [ue1|ue2|ue3|ue4|ue5]
# Starts a UDP echo server on this machine, sends 20 datagrams from the UE tunnel
# (same source binding as the dashboard) and shows where they are lost.
# Report: ~/oran-proof/diagnose-udp/<ts>-<ue>.txt
set -u
UE="${1:-ue1}"
NS="${NS:-oran-ran}"
case "$UE" in
  ue1) DEP=oai-nr-ue ;;
  ue[2-5]) DEP="oai-nr-ue-${UE#ue}" ;;
  *) echo "Usage: $0 ue1|ue2|ue3|ue4|ue5"; exit 1 ;;
esac

OUT="$HOME/oran-proof/diagnose-udp"; mkdir -p "$OUT"
REPORT="$OUT/$(date +%Y%m%d-%H%M%S)-$UE.txt"
exec > >(tee "$REPORT") 2>&1

section() { printf '\n==== %s ====\n' "$*"; }

NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"
POD="$(kubectl -n "$NS" get pods -l "app=$DEP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
TUN_IP="$(kubectl -n "$NS" exec "$POD" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null)"
PORT="$(python3 -c 'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0",0)); print(s.getsockname()[1])')"

section "TARGETS"
echo "node ip (echo server): $NODE_IP:$PORT"
echo "pod: ${POD:-none}   tunnel ip: ${TUN_IP:-none}"
[ -n "$POD" ] && [ -n "$TUN_IP" ] || { echo "VERDICT=UE_NOT_READY"; exit 1; }

section "UE SIDE ROUTE"
kubectl -n "$NS" exec "$POD" -- sh -c "ip route get $NODE_IP from $TUN_IP; ip -4 rule" 2>&1

section "HOST SIDE (route to the UE subnet, rp_filter, firewall)"
ip route get "$TUN_IP" 2>&1
sysctl net.ipv4.conf.all.rp_filter 2>&1
(iptables -S INPUT 2>&1 || sudo -n iptables -S INPUT 2>&1) | head -15
command -v ufw >/dev/null && (ufw status 2>&1 | head -5)

section "PROBE (20 datagrams of 1000 B, UE tunnel -> host echo -> UE tunnel)"
python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((sys.argv[2], int(sys.argv[1])))
s.settimeout(40)
n = 0
try:
    while True:
        d, a = s.recvfrom(65535); n += 1
        print("echo server saw datagram", n, "from", a[0]); sys.stdout.flush()
        s.sendto(d, a)
except Exception:
    print("echo server: received", n, "datagrams in total")
' "$PORT" "$NODE_IP" > "$OUT/.echo.$$" 2>&1 &
ECHO=$!
sleep 1
kubectl -n "$NS" exec "$POD" -- python3 -c '
import socket, sys, time
bind, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((bind, 0)); s.settimeout(0.3)
got = 0
for i in range(20):
    s.sendto(str(i).encode().ljust(1000, b"x"), (host, port))
    try:
        s.recvfrom(65535); got += 1
    except socket.timeout:
        pass
    time.sleep(0.05)
print("UE sent 20, received", got, "echoes")
' "$TUN_IP" "$NODE_IP" "$PORT" 2>&1
sleep 1; kill "$ECHO" 2>/dev/null; wait "$ECHO" 2>/dev/null
echo "--- host echo server view ---"
head -5 "$OUT/.echo.$$"; tail -1 "$OUT/.echo.$$"; rm -f "$OUT/.echo.$$"

section "HOW TO READ THIS"
cat <<'TXT'
 * "echo server saw datagram" lines are missing  -> datagrams do not reach the host
   (UPF/N6 forwarding or host firewall INPUT for udp).
 * the host saw them but the UE received 0 echoes -> the return path is broken
   (route to the UE subnet on the host, rp_filter, or UPF downlink).
 * UE received 20/20 here but the scenario fails  -> send me the dashboard output block.
TXT
echo; echo "Report saved to $REPORT"
