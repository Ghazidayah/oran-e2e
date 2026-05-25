#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-web}"
CM="${CM:-oran-dashboard-content}"
DEPLOY="${DEPLOY:-oran-dashboard}"
API_BASE="${API_BASE:-http://192.168.1.142:5055}"

BACKUP_DIR="$HOME/oran-proof/dashboard-backups/traffic-panel-$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$(mktemp -d)"

mkdir -p "$BACKUP_DIR"

echo "===== INSTALL PHASE 2 TRAFFIC PANEL INTO EXISTING DASHBOARD ====="
echo "NS=$NS"
echo "CM=$CM"
echo "DEPLOY=$DEPLOY"
echo "API_BASE=$API_BASE"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "WORK_DIR=$WORK_DIR"

echo "===== 1. BACKUP CURRENT CONFIGMAP ====="
kubectl -n "$NS" get configmap "$CM" -o yaml > "$BACKUP_DIR/${CM}.yaml"
kubectl -n "$NS" get configmap "$CM" -o json > "$WORK_DIR/configmap.json"

python3 - "$WORK_DIR/configmap.json" "$WORK_DIR" <<'PY'
import json
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
out = Path(sys.argv[2])

data = json.loads(json_path.read_text()).get("data", {})
(out / "index.html").write_text(data.get("index.html", ""))
(out / "status.json").write_text(data.get("status.json", "{}"))
PY

cp "$WORK_DIR/index.html" "$BACKUP_DIR/index.html"
cp "$WORK_DIR/status.json" "$BACKUP_DIR/status.json"

echo "===== 2. PATCH INDEX.HTML ====="
python3 - "$WORK_DIR/index.html" "$API_BASE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
api_base = sys.argv[2].rstrip("/")
html = path.read_text(errors="ignore")

start = "<!-- PHASE2_TRAFFIC_PANEL_START -->"
end = "<!-- PHASE2_TRAFFIC_PANEL_END -->"

panel = f"""
{start}
<section class="card section" id="phase2TrafficPanel">
  <h3>Realistic Traffic Scenarios - Phase 2</h3>
  <p class="small">
    These scenarios replace the old basic traffic tests with real application traffic through the UE tunnel.
  </p>

  <div class="grid cards">
    <div>
      <h3>Image Download</h3>
      <p class="small">HTTP image transfer through oaitun_ue1.</p>
      <button onclick="runPhase2Traffic('image', this)">Run Image</button>
    </div>

    <div>
      <h3>iperf3 TCP Throughput</h3>
      <p class="small">Measures TCP throughput over the UE tunnel.</p>
      <button onclick="runPhase2Traffic('iperf-tcp', this)">Run TCP</button>
    </div>

    <div>
      <h3>UDP Jitter / Loss</h3>
      <p class="small">Custom UDP packets for URLLC-style jitter and loss KPI.</p>
      <button onclick="runPhase2Traffic('udp', this)">Run UDP</button>
    </div>

    <div>
      <h3>Video Download</h3>
      <p class="small">Downloads a 10 MB video payload through oaitun_ue1.</p>
      <button onclick="runPhase2Traffic('video', this)">Run Video</button>
    </div>

    <div>
      <h3>Web Browsing</h3>
      <p class="small">Downloads HTML, CSS, JS and image resources.</p>
      <button onclick="runPhase2Traffic('web', this)">Run Web</button>
    </div>

    <div>
      <h3>Streaming-like HLS</h3>
      <p class="small">Downloads playlist and media segments.</p>
      <button onclick="runPhase2Traffic('streaming', this)">Run Streaming</button>
    </div>

    <div>
      <h3>Run All Realistic Traffic</h3>
      <p class="small">Runs all Phase 2 traffic scenarios.</p>
      <button onclick="runPhase2Traffic('run-all', this)">Run All</button>
    </div>
  </div>

  <pre id="phase2TrafficOutput" class="multi-ue-output">Traffic API ready: {api_base}</pre>
</section>

<script>
const PHASE2_TRAFFIC_API = "{api_base}";

function setPhase2TrafficOutput(text) {{
  const el = document.getElementById("phase2TrafficOutput");
  if (el) el.textContent = text || "";
}}

function setPhase2TrafficButtons(disabled, activeButton) {{
  document.querySelectorAll("#phase2TrafficPanel button").forEach((btn) => {{
    if (btn !== activeButton) btn.disabled = disabled;
  }});
}}

async function runPhase2Traffic(scenario, button) {{
  const originalText = button ? button.textContent : "";
  if (button) {{
    button.disabled = true;
    button.textContent = "Starting...";
  }}

  setPhase2TrafficButtons(true, button);
  setPhase2TrafficOutput("Starting Phase 2 scenario: " + scenario);

  try {{
    const startRes = await fetch(PHASE2_TRAFFIC_API + "/api/traffic/run/" + encodeURIComponent(scenario), {{
      method: "POST"
    }});

    const startData = await startRes.json();

    if (!startData.ok) {{
      throw new Error(startData.error || "Failed to start scenario");
    }}

    const jobId = startData.job_id;

    setPhase2TrafficOutput(
      "Started: " + startData.label + "\\n" +
      "Job ID: " + jobId + "\\n" +
      "Waiting for result..."
    );

    for (let i = 0; i < 300; i++) {{
      await new Promise((resolve) => setTimeout(resolve, 3000));

      const jobRes = await fetch(PHASE2_TRAFFIC_API + "/api/traffic/jobs/" + encodeURIComponent(jobId));
      const jobData = await jobRes.json();

      if (!jobData.ok) {{
        setPhase2TrafficOutput("Job lookup failed:\\n" + JSON.stringify(jobData, null, 2));
        continue;
      }}

      const job = jobData.job || {{}};
      const status = job.status || "unknown";

      setPhase2TrafficOutput(
        "Scenario: " + scenario + "\\n" +
        "Job ID: " + jobId + "\\n" +
        "Status: " + status + "\\n" +
        "Exit: " + (job.exit ?? "-") + "\\n" +
        "Proof: " + (job.job_dir || "-") + "\\n\\n" +
        "----- Output tail -----\\n" +
        (jobData.output || "")
      );

      if (["ok", "failed", "timeout", "error"].includes(status)) {{
        if (button) {{
          button.textContent = status === "ok" ? "Done ✓" : "Failed ✗";
        }}
        break;
      }}
    }}
  }} catch (err) {{
    setPhase2TrafficOutput("Traffic scenario failed: " + err);
    if (button) button.textContent = "Failed ✗";
  }} finally {{
    setPhase2TrafficButtons(false, button);
    if (button) {{
      setTimeout(() => {{
        button.textContent = originalText;
        button.disabled = false;
      }}, 2500);
    }}
  }}
}}
</script>
{end}
"""

if start in html and end in html:
    before = html.split(start)[0]
    after = html.split(end, 1)[1]
    html = before + panel + after
else:
    # Insert before the Kubernetes State section if present.
    marker = "Current Kubernetes State"
    idx = html.find(marker)
    if idx != -1:
        section_start = html.rfind("<section", 0, idx)
        if section_start != -1:
            html = html[:section_start] + panel + "\n" + html[section_start:]
        else:
            html = html.replace(marker, panel + "\n" + marker, 1)
    elif "</main>" in html:
        html = html.replace("</main>", panel + "\n</main>", 1)
    else:
        html += panel

path.write_text(html)
PY

echo "===== 3. APPLY UPDATED CONFIGMAP ====="
kubectl -n "$NS" create configmap "$CM" \
  --from-file=index.html="$WORK_DIR/index.html" \
  --from-file=status.json="$WORK_DIR/status.json" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "===== 4. RESTART DASHBOARD ====="
kubectl -n "$NS" rollout restart deploy/"$DEPLOY"
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=120s

echo "===== 5. VERIFY DASHBOARD HTML ====="
curl -s http://127.0.0.1:30080/ | grep -n "Realistic Traffic Scenarios - Phase 2"
curl -s http://127.0.0.1:30080/ | grep -n "runPhase2Traffic"

echo "===== OK ====="
echo "Dashboard: http://192.168.1.142:30080"
echo "Traffic API: $API_BASE"
echo "Backup: $BACKUP_DIR"
