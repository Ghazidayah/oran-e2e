let currentJobId = null;

function badge(ok) {
  return ok ? '<span class="badge ok">READY</span>' : '<span class="badge bad">NOT READY</span>';
}

function statusBadge(status) {
  if (status === "running") return '<span class="badge run">RUNNING</span>';
  if (status === "failed") return '<span class="badge bad">FAILED</span>';
  if (status === "stopped") return '<span class="badge bad">STOPPED</span>';
  return '<span class="badge ok">FINISHED</span>';
}

async function refreshStatus() {
  const res = await fetch("/api/status");
  const data = await res.json();

  document.getElementById("coreReady").textContent = data.summary.core_ready_count + "/3";
  document.getElementById("ranReady").textContent = data.summary.ran_ready_count + "/3";
  document.getElementById("monReady").textContent = data.summary.monitoring_ready_count;

  if (data.summary.job_running) {
    document.getElementById("jobState").textContent = "RUNNING";
    document.getElementById("jobName").textContent = data.summary.latest_job.label;
  } else if (data.summary.latest_job) {
    document.getElementById("jobState").textContent = data.summary.latest_job.status.toUpperCase();
    document.getElementById("jobName").textContent = data.summary.latest_job.label;
  } else {
    document.getElementById("jobState").textContent = "IDLE";
    document.getElementById("jobName").textContent = "No jobs yet";
  }

  fillPods("ranPods", data.pods.ran);
  fillPods("corePods", data.pods.core);
  fillEvidence(data.evidence.summaries);
  refreshJobs();
  refreshCurrentJob();
}

function fillPods(id, pods) {
  const el = document.getElementById(id);
  el.innerHTML = "";
  pods.forEach(p => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${p.name}</td>
      <td>${badge(p.ready)}</td>
      <td>${p.restarts}</td>
      <td>${p.ip || "-"}</td>
    `;
    el.appendChild(tr);
  });
}

function fillEvidence(items) {
  const el = document.getElementById("evidenceList");
  el.innerHTML = "";
  if (!items || items.length === 0) {
    el.innerHTML = '<div class="item">No evidence summaries found yet.</div>';
    return;
  }
  items.slice(0, 8).forEach(x => {
    const div = document.createElement("div");
    div.className = "item";
    div.innerHTML = `<strong>${x.name}</strong><code>${x.path}</code><br><small>${x.mtime}</small>`;
    el.appendChild(div);
  });
}

async function refreshJobs() {
  const res = await fetch("/api/jobs");
  const jobs = await res.json();
  const el = document.getElementById("jobHistory");
  el.innerHTML = "";
  if (!jobs || jobs.length === 0) {
    el.innerHTML = '<div class="item">No dashboard jobs yet.</div>';
    return;
  }
  jobs.slice(0, 10).forEach(j => {
    const div = document.createElement("div");
    div.className = "item";
    div.onclick = () => loadJobLog(j.id);
    div.innerHTML = `<strong>${j.label} ${statusBadge(j.status)}</strong><code>${j.id}</code><br><small>${j.started_at}</small>`;
    el.appendChild(div);
  });
}

async function startJob(action, danger=false) {
  if (danger) {
    const ok = confirm(
      "This action changes the lab state or may make the RAN dirty.\n\n" +
      "Evidence will be saved under ~/oran-proof.\n\n" +
      "Continue?"
    );
    if (!ok) return;
  }

  const res = await fetch("/api/jobs/start", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({action})
  });

  const data = await res.json();

  if (!data.ok) {
    alert(data.error || "Could not start job");
    return;
  }

  currentJobId = data.job.id;
  document.getElementById("logBox").textContent = "Started job: " + data.job.label + "\nWaiting for log...";
  refreshStatus();
}

async function stopJob() {
  const ok = confirm("Stop the running dashboard job?");
  if (!ok) return;

  const res = await fetch("/api/jobs/stop", {method: "POST"});
  const data = await res.json();

  if (!data.ok) {
    alert(data.error || "No running job");
  }

  refreshStatus();
}

async function refreshCurrentJob() {
  const res = await fetch("/api/jobs/current");
  const data = await res.json();
  if (!data.job) {
    document.getElementById("logBox").textContent = "No job log yet.";
    return;
  }
  currentJobId = data.job.id;
  document.getElementById("logBox").textContent = data.log || "No log output yet.";
}

async function loadJobLog(jobId) {
  const res = await fetch(`/api/jobs/${jobId}/log`);
  const data = await res.json();
  if (data.ok) {
    currentJobId = jobId;
    document.getElementById("logBox").textContent = data.log || "No log output.";
  }
}

refreshStatus();
setInterval(refreshStatus, 10000);
setInterval(refreshCurrentJob, 3000);
