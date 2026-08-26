#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generating the terminal fleet manifests.
#
# Role     : produce the four additional terminal deployments from a
#            reference configuration, rather than writing them by hand.
# Input    : manifests/ran/nrue.lab.conf
# Output   : manifests/ran/multi-ue/
# What varies between terminals: IMSI, the RFsim server address of its
#            serving DU, and the deployment name. Radio parameters stay
#            identical (106 blocks, numerology 1).
# Usage    : bash scripts/ue/generate-5ue-manifests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

SRC_CONF="manifests/ran/nrue.lab.conf"
OUT_DIR="manifests/ran/multi-ue"
IMAGE="oaisoftwarealliance/oai-nr-ue:2025.w45"

mkdir -p "$OUT_DIR"

if [ ! -f "$SRC_CONF" ]; then
  echo "[ERROR] Missing $SRC_CONF"
  exit 1
fi

KEY_VALUE=$(awk -F'"' '/key[[:space:]]*=/{print $2; exit}' "$SRC_CONF")
OPC_VALUE=$(awk -F'"' '/opc[[:space:]]*=/{print $2; exit}' "$SRC_CONF")

if [ -z "$KEY_VALUE" ] || [ -z "$OPC_VALUE" ]; then
  echo "[ERROR] Could not extract key/opc from $SRC_CONF"
  exit 1
fi

make_one() {
  n="$1"
  imsi="99970000000000${n}"
  dep="oai-nr-ue-${n}"
  cm="oai-nrue-config-${n}"
  app="oai-nr-ue-${n}"
  out="$OUT_DIR/${dep}.yaml"

  # Home DU per UE — encode it here so a cold deploy lands the UE on the
  # right DU's RFsim server without relying on the runtime recover step.
  # DU0 = oai-du0-rfsim, DU1 = oai-du1-rfsim. UE2-5 currently home on DU1.
  case "$n" in
    1)       home_rfsim="oai-du0-rfsim" ;;
    2|3|4|5) home_rfsim="oai-du1-rfsim" ;;
    *)       home_rfsim="oai-du1-rfsim" ;;
  esac

  cat > "$out" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${cm}
  namespace: oran-ran
data:
  nr-ue.conf: |
    uicc0 = {
      imsi = "${imsi}";
      key = "${KEY_VALUE}";
      opc = "${OPC_VALUE}";
      pdu_sessions = ({ dnn = "oai"; nssai_sst = 1; nssai_sd = 0xffffff; });
    }

    position0 = {
        x = 0.0;
        y = 0.0;
        z = 6377900.0;
    }

    thread-pool = "-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1"

    rfsimulator = (
      {
        serveraddr = "server";
      }
    );

    channelmod = {
      max_chan = 10;
      modellist = "modellist_rfsimu_1";
      modellist_rfsimu_1 = (
        {
          model_name     = "rfsimu_channel_enB0"
          type           = "AWGN";
          ploss_dB       = 20;
          noise_power_dB = -4;
          forgetfact     = 0;
          offset         = 0;
          ds_tdl         = 0;
        },
        {
          model_name     = "rfsimu_channel_ue0"
          type           = "AWGN";
          ploss_dB       = 20;
          noise_power_dB = -2;
          forgetfact     = 0;
          offset         = 0;
          ds_tdl         = 0;
        }
      );
    };
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${dep}
  namespace: oran-ran
spec:
  replicas: 0
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: ${app}
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: ${app}
        oran-ue: "true"
        ue-index: "${n}"
    spec:
      containers:
      - name: ${dep}
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        command:
        - /opt/oai-nr-ue/bin/nr-uesoftmodem
        args:
        - -O
        - /opt/oai-nr-ue/etc/nr-ue.conf
        - -E
        - --rfsim
        - -r
        - "106"
        - --numerology
        - "1"
        - -C
        - "3319680000"
        - --ssb
        - "516"
        - --rfsimulator.serveraddr
        - ${home_rfsim}
        - --rfsimulator.serverport
        - "4043"
        - --log_config.global_log_options
        - level,nocolor,time
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/sh
              - -lc
              - |-
                for i in \$(seq 1 120); do
                  if ip link show oaitun_ue1 >/dev/null 2>&1; then
                    ip route add 10.43.0.0/16 via 10.42.0.1 dev eth0 2>/dev/null || true
                    if ip route replace default dev oaitun_ue1 2>/dev/null; then
                      ip route | grep -q '^default dev oaitun_ue1' && exit 0
                    fi
                  fi
                  sleep 2
                done
                echo '[WARN] UE postStart could not enforce oaitun_ue1 default route' >&2
        resources:
          requests:
            cpu: "2"
            memory: 2Gi
          limits:
            cpu: "4"
            memory: 4Gi
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
            - SYS_NICE
        volumeMounts:
        - mountPath: /opt/oai-nr-ue/etc/nr-ue.conf
          name: nrue-config
          subPath: nr-ue.conf
        - mountPath: /dev/net/tun
          name: tun-device
      restartPolicy: Always
      volumes:
      - name: nrue-config
        configMap:
          name: ${cm}
      - name: tun-device
        hostPath:
          path: /dev/net/tun
          type: CharDevice
YAML

  echo "[OK] wrote $out"
}

for n in 2 3 4 5; do
  make_one "$n"
done
