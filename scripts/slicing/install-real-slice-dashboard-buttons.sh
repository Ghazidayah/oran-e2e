#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-http://192.168.1.142:5055}"
DASHBOARD_DIR="$HOME/oran-e2e-freeze/web-dashboard"
TEMPLATE="$DASHBOARD_DIR/templates/index.html"
JS="$DASHBOARD_DIR/static/dashboard-inline.js"
BACKUP_DIR="$HOME/oran-proof/dashboard-backups/real-slice-buttons-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

echo "===== INSTALL REAL S-NSSAI SLICE BUTTONS INTO DASHBOARD ====="
echo "API_BASE=$API_BASE"
echo "TEMPLATE=$TEMPLATE"
echo "JS=$JS"
echo "BACKUP_DIR=$BACKUP_DIR"

cp "$TEMPLATE" "$BACKUP_DIR/index.html.bak"
cp "$JS" "$BACKUP_DIR/dashboard-inline.js.bak"

python3 - "$TEMPLATE" "$JS" "$API_BASE" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
js_path = Path(sys.argv[2])
api_base = sys.argv[3].rstrip("/")

html = template_path.read_text(errors="ignore")
js = js_path.read_text(errors="ignore")

html_start = "<!-- PHASE3_REAL_SLICE_PANEL_START -->"
html_end = "<!-- PHASE3_REAL_SLICE_PANEL_END -->"

panel = f'''
{html_start}
<section class="card section" id="phase3RealSlicePanel">
  <h3>Real S-NSSAI Slice Traffic - Phase 3</h3>
  <p class="muted scenario-note">
    These buttons switch the OAI NR-UE requested S-NSSAI, validate oaitun_ue1, run realistic traffic, then restore the UE to default eMBB SST=1.
  </p>

  <div class="grid cards">
    <div>
      <h3>eMBB Real Slice</h3>
      <p class="small">SST=1, DNN=oai. Runs image, video, web, streaming and iperf TCP.</p>
      <button onclick="runRealSliceTraffic('embb', this)">Run eMBB Slice</button>
    </div>

    <div>
      <h3>URLLC Real Slice</h3>
      <p class="small">SST=2, DNN=oai. Runs UDP jitter/loss traffic.</p>
      <button onclick="runRealSliceTraffic('urllc', this)">Run URLLC Slice</button>
    </div>

    <div>
      <h3>mMTC Real Slice</h3>
      <p class="small">SST=3, DNN=oai. Runs IoT-style small UDP packets.</p>
      <button onclick="runRealSliceTraffic('mmtc', this)">Run mMTC Slice</button>
    </div>

  </div>

  <pre id="phase3RealSliceOutput" class="multi-ue-output">Real Slice API ready: {api_base}</pre>
</section>
{html_end}
'''

if html_start in html and html_end in html:
    before = html.split(html_start)[0]
    after = html.split(html_end, 1)[1]
    html = before + panel + after
else:
    # Put the real slice panel after the Phase 2 realistic traffic output section if possible.
    marker = '<pre id="phase2TrafficOutput"'
    idx = html.find(marker)
    if idx != -1:
        section_end = html.find("</section>", idx)
        if section_end != -1:
            insert_at = section_end + len("</section>")
            html = html[:insert_at] + "\n" + panel + html[insert_at:]
        else:
            html += "\n" + panel
    elif "</main>" in html:
        html = html.replace("</main>", panel + "\n</main>", 1)
    else:
        html += "\n" + panel

template_path.write_text(html)

js_start = "// PHASE3_REAL_SLICE_JS_START"
js_end = "// PHASE3_REAL_SLICE_JS_END"

block = f'''
{js_start}
const PHASE3_REAL_SLICE_API = "{api_base}";

function setPhase3RealSliceOutput(text) {{
  const el = document.getElementById("phase3RealSliceOutput");
  if (el) {{
    el.textContent = text || "";
  }}
}}

function setPhase3RealSliceButtons(disabled, activeButton) {{
  document.querySelectorAll('button[onclick*="runRealSliceTraffic"]').forEach((button) => {{
    if (button !== activeButton) {{
      button.disabled = disabled;
    }}
  }});
}}

async function runRealSliceTraffic(profile, button) {{
  const originalText = button ? button.textContent : "Run";
  if (button) {{
    button.disabled = true;
    button.textContent = "Starting...";
  }}

  setPhase3RealSliceButtons(true, button);
  setPhase3RealSliceOutput("Starting real S-NSSAI slice traffic profile: " + profile);

  try {{
    const startRes = await fetch(PHASE3_REAL_SLICE_API + "/api/traffic/run-real-slice/" + encodeURIComponent(profile), {{
      method: "POST"
    }});

    const startData = await startRes.json();

    if (!startData.ok) {{
      throw new Error(startData.error || "Failed to start real slice traffic");
    }}

    const jobId = startData.job_id;

    setPhase3RealSliceOutput(
      "Started: " + startData.label + "\\n" +
      "Profile: " + profile + "\\n" +
      "SST: " + startData.sst + "\\n" +
      "Job ID: " + jobId + "\\n" +
      "Waiting for result..."
    );

    for (let i = 0; i < 600; i++) {{
      await new Promise((resolve) => setTimeout(resolve, 3000));

      const jobRes = await fetch(PHASE3_REAL_SLICE_API + "/api/traffic/jobs/" + encodeURIComponent(jobId));
      const jobData = await jobRes.json();

      if (!jobData.ok) {{
        setPhase3RealSliceOutput("Job lookup failed:\\n" + JSON.stringify(jobData, null, 2));
        continue;
      }}

      const job = jobData.job || {{}};
      const status = job.status || "unknown";

      setPhase3RealSliceOutput(
        "Real Slice Profile: " + profile + "\\n" +
        "Label: " + (job.label || "-") + "\\n" +
        "SST: " + (job.sst ?? "-") + "\\n" +
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
    setPhase3RealSliceOutput("Real slice traffic failed: " + error);
    if (button) {{
      button.textContent = "Failed ✗";
    }}
  }} finally {{
    setPhase3RealSliceButtons(false, button);
    if (button) {{
      setTimeout(() => {{
        button.textContent = originalText;
        button.disabled = false;
      }}, 2500);
    }}
  }}
}}
{js_end}
'''

if js_start in js and js_end in js:
    before = js.split(js_start)[0]
    after = js.split(js_end, 1)[1]
    js = before + block + after
else:
    js = js.rstrip() + "\n\n" + block + "\n"

js_path.write_text(js)
PY

echo
echo "===== VERIFY PATCH ====="
grep -n "Real S-NSSAI Slice Traffic - Phase 3" "$TEMPLATE"
grep -n "runRealSliceTraffic" "$JS"

echo
echo "===== DONE ====="
echo "Backup saved in: $BACKUP_DIR"
