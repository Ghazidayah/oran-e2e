#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-http://192.168.1.142:5055}"
DASHBOARD_DIR="$HOME/oran-e2e/web-dashboard"
TEMPLATE="$DASHBOARD_DIR/templates/index.html"
JS="$DASHBOARD_DIR/static/dashboard-inline.js"
BACKUP_DIR="$HOME/oran-proof/dashboard-backups/flask-realistic-scenarios-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

echo "===== INSTALL REALISTIC SCENARIOS INTO FLASK DASHBOARD ====="
echo "API_BASE=$API_BASE"
echo "TEMPLATE=$TEMPLATE"
echo "JS=$JS"
echo "BACKUP_DIR=$BACKUP_DIR"

cp "$TEMPLATE" "$BACKUP_DIR/index.html.bak"
cp "$JS" "$BACKUP_DIR/dashboard-inline.js.bak"

python3 - "$TEMPLATE" "$JS" "$API_BASE" <<'PY'
import re
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
js_path = Path(sys.argv[2])
api_base = sys.argv[3].rstrip("/")

html = template_path.read_text(errors="ignore")
js = js_path.read_text(errors="ignore")

new_section = f'''
<section class="card section">
  <h3>End-to-End UE Validation Scenarios</h3>
  <p class="muted scenario-note">
    Baseline validation is kept, while old ping-like traffic scenarios are replaced by realistic Phase 2 service traffic.
  </p>

  <div class="grid cards">
    <div>
      <h3>Serving gNB Check</h3>
      <p class="small">Shows the serving cell for selected UE(s).</p>
      <button onclick="runActionInteractive('ownership', this)">Check Serving gNB</button>
    </div>

    <div>
      <h3>UE Attach + PDU Session</h3>
      <p class="small">Checks attach, PDU session, and RAN-Core path.</p>
      <button onclick="runUeScenarioInteractive('attach_pdu', this)">Validate UE Session</button>
    </div>

    <div>
      <h3>UE Connectivity Test</h3>
      <p class="small">Tests DN gateway reachability through selected UE tunnel(s).</p>
      <button onclick="runUeScenarioInteractive('connectivity', this)">Run Connectivity</button>
    </div>

    <div>
      <h3>Image Download</h3>
      <p class="small">Downloads a real image payload through oaitun_ue1.</p>
      <button onclick="runPhase2Traffic('image', this)">Run Image</button>
    </div>

    <div>
      <h3>iperf3 TCP Throughput</h3>
      <p class="small">Measures TCP throughput over the UE tunnel.</p>
      <button onclick="runPhase2Traffic('iperf-tcp', this)">Run TCP</button>
    </div>

    <div>
      <h3>UDP Jitter / Loss</h3>
      <p class="small">Runs custom UDP traffic for jitter and packet-loss KPIs.</p>
      <button onclick="runPhase2Traffic('udp', this)">Run UDP</button>
    </div>

    <div>
      <h3>Video Download</h3>
      <p class="small">Downloads a 10 MB video payload through the UE tunnel.</p>
      <button onclick="runPhase2Traffic('video', this)">Run Video</button>
    </div>

    <div>
      <h3>Web Browsing</h3>
      <p class="small">Downloads HTML, CSS, JS and image resources.</p>
      <button onclick="runPhase2Traffic('web', this)">Run Web</button>
    </div>

    <div>
      <h3>Streaming-like HLS</h3>
      <p class="small">Downloads a playlist and several media segments.</p>
      <button onclick="runPhase2Traffic('streaming', this)">Run Streaming</button>
    </div>

    <div>
      <h3>Run All Realistic Traffic</h3>
      <p class="small">Runs all Phase 2 scenarios and creates a full evidence suite.</p>
      <button onclick="runPhase2Traffic('run-all', this)">Run All</button>
    </div>
  </div>

  <pre id="phase2TrafficOutput" class="multi-ue-output">Traffic API ready: {api_base}</pre>
</section>
'''

pattern = re.compile(
    r'<section class="card section">\s*<h3>End-to-End UE Validation Scenarios</h3>.*?</section>',
    re.S
)

html_new, count = pattern.subn(new_section, html, count=1)

if count != 1:
    raise SystemExit("Could not replace End-to-End UE Validation Scenarios section")

template_path.write_text(html_new)

start = "// PHASE2_TRAFFIC_JS_START"
end = "// PHASE2_TRAFFIC_JS_END"

block = f'''
{start}
const PHASE2_TRAFFIC_API = "{api_base}";

function setPhase2TrafficOutput(text) {{
  const el = document.getElementById("phase2TrafficOutput");
  if (el) {{
    el.textContent = text || "";
  }}
}}

function setPhase2TrafficButtons(disabled, activeButton) {{
  document.querySelectorAll('button[onclick*="runPhase2Traffic"]').forEach((button) => {{
    if (button !== activeButton) {{
      button.disabled = disabled;
    }}
  }});
}}

async function runPhase2Traffic(scenario, button) {{
  const originalText = button ? button.textContent : "Run";
  if (button) {{
    button.disabled = true;
    button.textContent = "Starting...";
  }}

  setPhase2TrafficButtons(true, button);
  setPhase2TrafficOutput("Starting realistic traffic scenario: " + scenario);

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
  }} catch (error) {{
    setPhase2TrafficOutput("Traffic scenario failed: " + error);
    if (button) {{
      button.textContent = "Failed ✗";
    }}
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
{end}
'''

if start in js and end in js:
    before = js.split(start)[0]
    after = js.split(end, 1)[1]
    js = before + block + after
else:
    js = js.rstrip() + "\n\n" + block + "\n"

js_path.write_text(js)
PY

echo "===== VERIFY PATCH ====="
grep -n "Image Download" "$TEMPLATE"
grep -n "runPhase2Traffic" "$JS"

echo "===== DONE ====="
echo "Backup saved in: $BACKUP_DIR"
