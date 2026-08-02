# Project File Map

This document explains the purpose of the main files and folders in this project.

Generated from the actual repository tree. Every tracked file is listed; the only
omission is `docs/baselines/.../` whose individual capture files are covered as a folder
at the end of this document.

## Project root

- `.gitignore`  
  Ignore rules for runtime artifacts (venv, logs, generated KPI JSON, snapshots). Carries an explicit exception so the `docs/proofs/*.pcap` evidence captures stay tracked despite the global `*.pcap` rule.

- `OPERATING-RULES.md`  
  Project safety rules and platform reference; read before running anything against the live cluster.

- `README.md`  
  Short project overview for the frozen O-RAN / Open5GS / OAI lab state.

- `run-web-dashboard.sh`  
  Starts the Flask web dashboard.

- `stop-web-dashboard.sh`  
  Stops the Flask web dashboard.

## Config

- `config/ues.yaml`  
  Defines the 5-UE inventory used by the dashboard and multi-UE control logic.

## Core manifests

- `manifests/core/amf.yaml`  
  Open5GS AMF configuration.

- `manifests/core/open5gs-5gsa.yaml`  
  Main Open5GS 5G SA deployment manifest.

- `manifests/core/open5gs-amf-deploy-live.yaml`  
  Captured/live AMF deployment manifest used to freeze the validated baseline.

- `manifests/core/open5gs-oai-prep-configmap-live.yaml`  
  Captured Open5GS configuration ConfigMap used by the working OAI/Open5GS integration.

- `manifests/core/open5gs-overrides.yaml`  
  Small override values used during Open5GS setup.

- `manifests/core/open5gs-upf-deploy-live.yaml`  
  Captured/live UPF deployment manifest used to freeze the validated baseline.

- `manifests/core/smf.yaml`  
  Open5GS SMF configuration.

- `manifests/core/upf.yaml`  
  Open5GS UPF configuration.

## Network manifests

- `manifests/network/n2-net-core.yaml`  
  Multus N2 network attachment for core-side pods.

- `manifests/network/n2-net-ran.yaml`  
  Multus N2 network attachment for RAN-side pods.

- `manifests/network/n3-net-core.yaml`  
  Multus N3 network attachment for core-side pods.

- `manifests/network/n3-net-ran.yaml`  
  Multus N3 network attachment for RAN-side pods.

## RAN manifests - E1 split (CU-CP / CU-UP)

- `manifests/ran/e1/cucp.conf`  
  CU-CP (control plane): RRC + NGAP->AMF + F1-C + E1 server.

- `manifests/ran/e1/cuup.conf`  
  CU-UP (user plane): PDCP/SDAP + NG-U->UPF + F1-U + E1 client.

- `manifests/ran/e1/e1-split.yaml`  
  ConfigMap `oai-cucp-config`.

## RAN manifests - F1 split (DU0 / DU1)

- `manifests/ran/f1/du0.conf`  
  SPDX-License-Identifier: LicenseRef-CSSL-1.0.

- `manifests/ran/f1/du1.conf`  
  SPDX-License-Identifier: LicenseRef-CSSL-1.0.

- `manifests/ran/f1/f1-ran.yaml`  
  Deployment `oai-du0`.

## RAN manifests - multi-UE sources

- `manifests/ran/multi-ue/oai-nr-ue-2.yaml`  
  UE2 deployment manifest.

- `manifests/ran/multi-ue/oai-nr-ue-3.yaml`  
  UE3 deployment manifest.

- `manifests/ran/multi-ue/oai-nr-ue-4.yaml`  
  UE4 deployment manifest.

- `manifests/ran/multi-ue/oai-nr-ue-5.yaml`  
  UE5 deployment manifest.

## RAN manifests - captured live state (evidence, never applied verbatim)

- `manifests/ran/mixed-du-live/cm-oai-nrue-config-2.yaml`  
  ConfigMap `oai-nrue-config-2`.

- `manifests/ran/mixed-du-live/cm-oai-nrue-config-3.yaml`  
  ConfigMap `oai-nrue-config-3`.

- `manifests/ran/mixed-du-live/cm-oai-nrue-config-4.yaml`  
  ConfigMap `oai-nrue-config-4`.

- `manifests/ran/mixed-du-live/cm-oai-nrue-config-5.yaml`  
  ConfigMap `oai-nrue-config-5`.

- `manifests/ran/mixed-du-live/cm-oai-nrue-config.yaml`  
  ConfigMap `oai-nrue-config`.

- `manifests/ran/mixed-du-live/deploy-oai-du0.yaml`  
  Deployment `oai-du0`.

- `manifests/ran/mixed-du-live/deploy-oai-du1.yaml`  
  Deployment `oai-du1`.

- `manifests/ran/mixed-du-live/deploy-oai-nr-ue-2.yaml`  
  Deployment `oai-nr-ue-2`.

- `manifests/ran/mixed-du-live/deploy-oai-nr-ue-3.yaml`  
  Deployment `oai-nr-ue-3`.

- `manifests/ran/mixed-du-live/deploy-oai-nr-ue-4.yaml`  
  Deployment `oai-nr-ue-4`.

- `manifests/ran/mixed-du-live/deploy-oai-nr-ue-5.yaml`  
  Deployment `oai-nr-ue-5`.

- `manifests/ran/mixed-du-live/deploy-oai-nr-ue.yaml`  
  Deployment `oai-nr-ue`.

- `manifests/ran/mixed-du-live/svc-oai-du0-rfsim.yaml`  
  Service `oai-du0-rfsim`.

- `manifests/ran/mixed-du-live/svc-oai-du1-rfsim.yaml`  
  Service `oai-du1-rfsim`.

## RAN manifests - other

- `manifests/ran/nrue.lab.conf`  
  Base OAI NR-UE configuration for the lab.

## Scripts - platform

- `scripts/bootstrap-platform.sh`  
  bootstrap-platform.sh — Fresh Ubuntu 22.04 host → running O-RAN E2E platform.

- `scripts/deploy-core.sh`  
  Deploys the Open5GS core.

- `scripts/gather-report-data.sh`  
  Collects configs, live platform state, KPI JSONs, and logs into a single report bundle (read-only).

- `scripts/platform-start.sh`  
  Restarts the platform from the saved replica state and reconciles the UE sessions.

- `scripts/platform-stop.sh`  
  Scales the platform down and saves the current replica state for a later restart.

- `scripts/recover-ue-sessions.sh`  
  recover-ue-sessions.sh — diagnose-first recovery after a core/CU event.

- `scripts/validate-e2e.sh`  
  Validates the E2E baseline, including pod status and UE tunnel readiness.

- `scripts/validate-f1-ran.sh`  
  Prints RAN and core pod status, F1/E1/NGAP logs, and the UE1 tunnel for a quick F1 RAN check.

## Scripts - UE

- `scripts/ue/generate-5ue-manifests.sh`  
  Generates or updates multi-UE manifests.

- `scripts/ue/provision-5ue-subscribers.sh`  
  Provisions UE1-UE5 subscribers in Open5GS.

- `scripts/ue/ue-common.sh`  
  Shared library of UE helper functions (pod, selector, tunnel IP, serveraddr, slice lookups) sourced by other scripts.

- `scripts/ue/uectl.sh`  
  Helper script for controlling UE deployments.

## Scripts - frequency / FSPL

- `scripts/frequency/apply-fspl-band-profile.sh`  
  apply-fspl-band-profile.sh — emulate frequency-band path loss as a throughput cap.

- `scripts/frequency/audit-actual-frequency-retune-readiness.sh`  
  Audits readiness for a real carrier retune (API, ConfigMaps, deployments) and writes the findings as proof.

- `scripts/frequency/compute-fspl-k.sh`  
  compute-fspl-k.sh — derive relative degradation coefficient K from FSPL model.

- `scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh`  
  Performs a real DU-aware OAI carrier retune for UE1, following the UE's current DU.

## Scripts - slicing

- `scripts/slicing/apply-phase4-qos-resource-profiles.sh`  
  Applies per-slice QoS/AMBR/ARP profiles to the Open5GS subscribers in MongoDB, with a safety backup.

- `scripts/slicing/apply-real-snssai-slicing.sh`  
  DU-aware safety guard.

- `scripts/slicing/apply-slice-resource-profile.sh`  
  Applies a per-slice tc tbf/netem shaping profile (rate as a % of the measured ceiling) to UE1's tunnel.

- `scripts/slicing/install-real-slice-dashboard-buttons.sh`  
  One-off installer that patches the real-slice buttons into the dashboard template and JS (backs up first).

- `scripts/slicing/rollback-phase4-qos-resource-profiles.sh`  
  Rolls the per-slice QoS profiles in MongoDB back to the phase-3 shared template.

- `scripts/slicing/rollback-real-snssai-slicing.sh`  
  Restores the AMF/SMF/NSSF/CU ConfigMaps from a saved backup to undo real S-NSSAI slicing.

- `scripts/slicing/run-real-slice-traffic.sh`  
  Switches UE1 to a real slice (embb/urllc/mmtc), applies the resource profile, runs the scenario traffic, then restores SST=1.

- `scripts/slicing/switch-ue-slice.sh`  
  Real S-NSSAI slice switch for protected UE1 (v2, 2026-06-10).

- `scripts/slicing/validate-current-slice.sh`  
  Validate protected UE1's CURRENT slice (v2, 2026-06-10).

## Scripts - traffic

- `scripts/traffic/install-multi-ue-embb-realistic-scenarios.sh`  
  One-off installer that patches the multi-UE eMBB realistic scenarios into the dashboard JS/HTML and multi_ue_api.py (backs up first).

- `scripts/traffic/install-realistic-scenarios-flask-dashboard.sh`  
  One-off installer that patches the realistic-traffic scenario buttons into the Flask dashboard template and JS (backs up first).

- `scripts/traffic/install-traffic-dashboard-panel.sh`  
  One-off installer that patches a traffic panel into the oran-web dashboard ConfigMap (backs up first).

- `scripts/traffic/measure-ceiling.sh`  
  Auto-calibration du PLAFOND de débit (UL TCP non-capé, UE1 isolé).

- `scripts/traffic/run-all-realistic-traffic.sh`  
  Runs the full Phase 2 realistic-traffic suite (image, iperf-TCP, UDP, video, web, streaming) in sequence.

- `scripts/traffic/run-image-download.sh`  
  Serves a test image and downloads it over UE1's tunnel, verifying integrity by SHA-256.

- `scripts/traffic/run-iperf-tcp.sh`  
  Runs an iperf3 TCP throughput test over UE1's tunnel (default 15 s).

- `scripts/traffic/run-streaming-like.sh`  
  Downloads an HLS-like segmented stream (default 8 segments) over UE1's tunnel and checks segment integrity.

- `scripts/traffic/run-udp-traffic.sh`  
  Sends a custom UDP stream over UE1's tunnel and measures packet loss and jitter.

- `scripts/traffic/run-video-download.sh`  
  Downloads a test video file over UE1's tunnel, verifying integrity by checksum.

- `scripts/traffic/run-web-browsing.sh`  
  Fetches a multi-resource web page over UE1's tunnel and checks that all resources load.

- `scripts/traffic/start-traffic-api.sh`  
  Starts the Phase 2 traffic API server (`traffic_api_server.py`) on port 5055.

- `scripts/traffic/stop-traffic-api.sh`  
  Stops the Phase 2 traffic API server and confirms it is no longer running.

- `scripts/traffic/test-all-scenarios.sh`  
  test-all-scenarios.sh — run every Phase-2 realistic-traffic scenario in sequence.

- `scripts/traffic/traffic_api_server.py`  
  !/usr/bin/env python3.

## Scripts - handover

- `scripts/handover/recover-mixed-du-state.sh`  
  Recovers UE3-UE5 on DU1, restores UE1 to baseline DU0, and reruns the Mixed-DU validation (safe mode, no hard exit).

- `scripts/handover/switch-ue-du-target.sh`  
  Switches a UE between DU0 and DU1 (UE1's baseline home is DU0).

## Scripts - radio

- `scripts/radio/switch-ue-modulation-profile-du-aware.sh`  
  Real forced-MCS modulation profiles for UE1 (replaces the netem-faked radio profiles).

## Scripts - dashboard

- `scripts/dashboard/audit-dashboard-and-platform.sh`  
  Audits the dashboard endpoints and overall platform state, saving the results as proof.

## Acceptance suite

- `tests/run-full-platform-acceptance.sh`  
  Runs the whole platform acceptance suite non-stop and prints a single pass/fail summary table.

- `tests/test-section-01-baseline-e2e.sh`  
  Acceptance suite section 1: baseline end-to-end checks (pods, tunnels, UE1 connectivity).

- `tests/test-section-02-realistic-traffic.sh`  
  Acceptance suite section 2: realistic traffic scenario checks.

- `tests/test-section-03-real-slices.sh`  
  Acceptance suite section 3: real S-NSSAI slice (eMBB/URLLC/mMTC) checks.

- `tests/test-section-04-radio-profiles.sh`  
  Acceptance suite section 4: radio/modulation profile checks.

- `tests/test-section-05-multi-ue-embb.sh`  
  Acceptance suite section 5: multi-UE eMBB scenario checks.

- `tests/test-section-06-mixed-du-handover.sh`  
  Acceptance suite section 6: mixed-DU handover checks.

- `tests/test-section-07-final-regression.sh`  
  Acceptance suite section 7: final regression checks.

## Web dashboard - application

- `web-dashboard/README.md`  
  Dashboard-specific notes.

- `web-dashboard/app.py`  
  Main Flask dashboard application. Provides status, live metrics, and single-UE action APIs.

- `web-dashboard/handover_api.py`  
  Flask blueprint serving the handover status endpoint (`/api/handover/status`).

- `web-dashboard/mixed_du_handover_api.py`  
  Registers the mixed-DU handover endpoints (`/api/handover/mixed-du/*`: status, switch, run, recover).

- `web-dashboard/multi_ue_api.py`  
  Multi-UE dashboard API. Handles UE inventory, desired UE count, per-UE start/stop/ping, and selected-UE scenario execution.

- `web-dashboard/radio_profile_api.py`  
  Flask blueprint for the radio/modulation profile endpoints (`/api/radio/*`: status, apply, kpi-test, restore).

- `web-dashboard/real_frequency_api.py`  
  Plafond reel = debit UL TCP non-capped (UE1 isole). AUTO-MESURE par.

- `web-dashboard/requirements.txt`  
  Python dependencies for the Flask dashboard.

- `web-dashboard/run-dashboard.sh`  
  Starts the dashboard from inside the dashboard folder.

- `web-dashboard/traffic_kpi_api.py`  
  Flask blueprint that parses traffic job logs into the consolidated E2E KPI results (`/api/e2e-kpi/results`).

## Web dashboard - action scripts

- `web-dashboard/actions/ci_ownership.sh`  
  Checks serving gNB / UE ownership through OAI telnet CI commands.

- `web-dashboard/actions/collect_snapshot.sh`  
  Collects logs and runtime state snapshots.

- `web-dashboard/actions/common.sh`  
  Shared shell helpers for dashboard actions.

- `web-dashboard/actions/f1_status.sh`  
  Dashboard action script that reports F1 topology and UE tunnel status.

- `web-dashboard/actions/validate_e2e.sh`  
  Dashboard action for E2E validation.

## Web dashboard - static assets

- `web-dashboard/static/dashboard-inline.js`  
  Remaining dashboard logic after status/live split.

- `web-dashboard/static/dashboard-multi-ue.js`  
  Multi-UE Control dashboard logic.

- `web-dashboard/static/dashboard-status-live.js`  
  Extracted from index.html script block 1.

- `web-dashboard/static/dashboard-ui-feedback.js`  
  Shared dashboard button feedback.

- `web-dashboard/static/mixed-du-handover.js`  
  Front-end JS for the radio/modulation profile panel (profile select, apply, KPI test, results table).

- `web-dashboard/static/mixed-du-table.js`  
  Front-end JS that renders the mixed-DU UE table and drives the per-UE DU-switch buttons (`/api/handover/mixed-du/*`).

- `web-dashboard/static/real-frequency.js`  
  Front-end JS for the real-frequency panel (band run/refresh/restore buttons and results table).

- `web-dashboard/static/style.css`  
  Dashboard styling.

## Web dashboard - templates

- `web-dashboard/templates/index.html`  
  Main dashboard UI template.

## Documentation - reference (current, authoritative)

- `docs/reference/DEPLOYMENT-GUIDE.md`  
  Fresh-host build procedure (Ubuntu 22.04 to running platform), consolidated from the March 2026 deployment report and the current repo. Spots that could not be verified from the sources are marked `TODO`.

- `docs/reference/NETWORK-TOPOLOGY.md`  
  Address plan and datapath: single-node k3s, Multus secondary NICs, N2/N3 Linux bridges, per-pod fixed IPs.

- `docs/reference/TROUBLESHOOTING.md`  
  Symptom-to-fix guide for the running platform, starting from a read-only health check.

- `docs/reference/cold-start-recovery.md`  
  Root cause and permanent fix for the Open5GS cold-start ordering failure (a stock Open5GS-on-Kubernetes weakness the E1 work exposed, not an E1 defect).

- `docs/reference/SLICING-TRUTH.md`  
  What the platform really does about slicing: SST=1 baseline at cold start, and what changes when the slicing scripts are applied.

- `docs/reference/FSPL-FREQUENCY-DEGRADATION.md`  
  Why and how carrier frequency is made to matter: RFsim ignores frequency for path loss, so an FSPL-derived per-band netem profile is applied instead.

- `docs/reference/what-is-real-vs-emulated.md`  
  Single-source reference separating genuine 3GPP procedures from deliberately synthesized behaviour. Read before making any claim about the platform.

- `docs/reference/LIMITATIONS-AND-FUTURE-WORK.md`  
  Deliberate scoping decisions and the extensions needed to move from validation platform toward production. Each item is a stated trade-off, not an oversight.

- `docs/reference/demo-dry-run-checklist.md`  
  Click-by-click demo runbook: what each step proves, plus inline recovery for the one component that may fail mid-demo (the CU).

- `docs/reference/PROJECT-FILE-MAP.md`  
  This document.

- `docs/reference/REPO-RESTRUCTURE-PLAN.md`  
  Proposed directory restructure, written 2026-07-11. **DEFERRED and NOT APPLIED** - it describes a target layout that does not match the current tree. Post-defense work only.

## Documentation - evidence captures

- `docs/proofs/README.md`  
  Manifest for the four PCAP captures: address map, per-file frame tables, what to point a jury at, and why two earlier pre-E1-split captures were excluded.

- `docs/proofs/01-e1ap-cuup-setup.pcap`  
  E1AP: CU-UP registering with CU-CP (15 frames). Written in pcapng format despite the `.pcap` extension; Wireshark and tshark read it transparently.

- `docs/proofs/02-f1ap-setup-rrc-attach.pcap`  
  F1 setup, full RRC attach, and E1 bearer context setup interleaved in one trace (60 frames). The richest capture in the set.

- `docs/proofs/03-n2-ngap-registration.pcap`  
  NGAP between CU-CP and AMF: complete 5G SA registration and PDU session establishment (51 frames).

- `docs/proofs/04-n3-gtpu-userplane.pcap`  
  GTP-U between CU-UP and UPF carrying real UE traffic to the internet (41 G-PDUs, bidirectional TEIDs).

- `docs/proofs/f1-handover-success.txt`  
  Captured console evidence of the F1 RFsim handover succeeding (2026-05-17).

## Documentation - validation records

Dated records of each capability as it was proven. Historical by nature: they describe the
platform at the date on the file, not necessarily the frozen state.

- `docs/validation/phase2-realistic-traffic.md`  
  Phase 2: moving beyond ping-only validation to realistic application traffic scenarios.

- `docs/validation/phase2-dashboard-realistic-scenarios-validation.md`  
  Phase 2 scenarios wired into the dashboard, replacing the earlier basic traffic cards.

- `docs/validation/phase3-real-snssai-slicing-validation.md`  
  Phase 3: enabling and validating real S-NSSAI slicing across AMF, SMF, NSSF, CU and DUs.

- `docs/validation/slicing-real-snssai-validation.md`  
  Root cause analysis behind the first genuinely granted non-default slice on the platform (2026-06-10).

- `docs/validation/phase3-real-slice-traffic-validation.md`  
  Phase 3 continued: realistic application traffic running on top of real slice selection.

- `docs/validation/phase4-qos-resource-profiles.md`  
  Phase 4: per-slice QoS and resource behaviour, beyond merely changing SST.

- `docs/validation/ue-slice-alignment-validation.md`  
  UE2-UE5 slice assignments aligned across UE configs, MongoDB defaults and DU slice lists (2026-06-11).

- `docs/validation/modulation-scenarios-validation.md`  
  Real forced modulation-order control via the DU MAC scheduler MCS caps, replacing the earlier netem-faked radio profiles.

- `docs/validation/frequency-scenarios-validation.md`  
  Frequency scenario validation on the DU-aware architecture (2026-06-09).

- `docs/validation/frequency-kpi-comparison-validation.md`  
  Fix to the measurement behind the dashboard's frequency-band KPI table. Does not touch the carrier retune itself.

- `docs/validation/mixed-du-multi-ue-validation.md`  
  Mixed-DU continuity design validated across multiple UEs (2026-05-29).

- `docs/validation/mixed-du-dashboard-handover-validation.md`  
  The validated mixed-DU design integrated into the dashboard handover section.

- `docs/validation/ue1-du-aware-handover-validation.md`  
  DU-aware handover design and evidence, re-validated 2026-06-11.

- `docs/validation/f1-du-switch-validation-summary.md`  
  Summary of the F1 DU switch redesign into a clean OAI F1-split architecture.

- `docs/validation/du-aware-phase3-phase4-e2e-validation.md`  
  Phase 3, Phase 4 and E2E validation scripts made safe under the mixed-DU architecture.

- `docs/validation/session-report-20260609.md`  
  Working session record, 2026-06-09.

- `docs/validation/session-report-20260624.md`  
  Working session record, 2026-06-24. Carries an explicit note (added 2026-07-30) that it is a historical record and must not be used as a current reference.

- `docs/validation/rapport-session-20260710-20260712.md`  
  Session report for 10-12 July 2026 (French).

## Documentation - archive (superseded)

Kept for traceability. These describe earlier architectures and must not be read as current.

- `docs/archive/full-project-report-2026-06-14.md`  
  Full change log, 2026-04-07 to 2026-06-14. The single largest historical record; many paths it cites no longer exist.

- `docs/archive/repo-inventory-20260612.md`  
  Repository inventory taken before the cleanup pass, with a verdict per file.

- `docs/archive/DASHBOARD-FULL-PLATFORM-VALIDATION-20260518.md`  
  Dashboard platform validation in two operational modes, 2026-05-18.

- `docs/archive/dashboard-full-test-report-2026-06-11.md`  
  Full dashboard test report, 2026-06-11.

- `docs/archive/f1-du-handover-redesign-plan.md`  
  Decision record for removing the old broken handover section and redesigning it.

- `docs/archive/radio-profile-netem-final-validation-20260602.md`  
  Record of the negative result: RFsim-only MCS forcing was never proven, which is why the netem-based approach was adopted.

## Monitoring

- `monitoring/grafana/dashboards/oran-lab-dashboard.json`  
  Grafana dashboard "O-RAN 5G Lab - Operations Dashboard", 14 panels. Plain dashboard JSON.

- `monitoring/grafana/dashboards/oran-5g-lab-ops.improved.json`  
  Improved revision of the same dashboard, 17 panels. Wrapped in a `meta` + `dashboard` envelope (Grafana API export shape), so import it via the API or unwrap the `dashboard` key first.

## Folders (hand-written notes, preserved)

- `docs/baselines/stable-e2e-before-ho-debug-20260503-101700/`  
  Historical stable baseline evidence captured before handover debugging. Keep for traceability.

- `manifests/ran/mixed-du-live/`  
  Snapshots of the running cluster (`kubectl -o yaml`), kept as evidence — NOT a deployment source. Never applied verbatim (OPERATING-RULES.md rule 4); the `multi-ue/` files above are the clean source manifests applied directly.

- `web-dashboard/.venv/`  
  Local Python virtual environment. Keep locally unless recreating the environment.
