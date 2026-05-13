# Project File Map

This document explains the purpose of the main files and folders in this project.

Project root:

- `README.md`  
  Short project overview for the frozen O-RAN / Open5GS / OAI lab state.

- `.gitignore`  
  Ignores local runtime files, backup files, Python virtual environments, logs, and generated artifacts.

- `.last-stable-baseline`  
  Records the last known stable baseline tag used during earlier recovery work.

- `.last-stable-baseline-clean`  
  Records the last clean stable baseline tag.

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

- `manifests/core/smf.yaml`  
  Open5GS SMF configuration.

- `manifests/core/upf.yaml`  
  Open5GS UPF configuration.

- `manifests/core/open5gs-5gsa.yaml`  
  Main Open5GS 5G SA deployment manifest.

- `manifests/core/open5gs-amf-deploy-live.yaml`  
  Captured/live AMF deployment manifest used to freeze the validated baseline.

- `manifests/core/open5gs-upf-deploy-live.yaml`  
  Captured/live UPF deployment manifest used to freeze the validated baseline.

- `manifests/core/open5gs-oai-prep-configmap-live.yaml`  
  Captured Open5GS configuration ConfigMap used by the working OAI/Open5GS integration.

- `manifests/core/open5gs-overrides.yaml`  
  Small override values used during Open5GS setup.

## Network manifests

- `manifests/network/99-oran-bridges.yaml`  
  Bridge/network preparation manifest for the lab.

- `manifests/network/n2-net-core.yaml`  
  Multus N2 network attachment for core-side pods.

- `manifests/network/n2-net-ran.yaml`  
  Multus N2 network attachment for RAN-side pods.

- `manifests/network/n3-net-core.yaml`  
  Multus N3 network attachment for core-side pods.

- `manifests/network/n3-net-ran.yaml`  
  Multus N3 network attachment for RAN-side pods.

## RAN manifests

- `manifests/ran/gnb.lab.conf`  
  Base OAI gNB configuration for the lab.

- `manifests/ran/nrue.lab.conf`  
  Base OAI NR-UE configuration for the lab.

- `manifests/ran/oai-gnb-configmap-live.yaml`  
  Captured/live gNB ConfigMap used by the working baseline.

- `manifests/ran/oai-gnb-deploy-live.yaml`  
  Captured/live gNB-A deployment manifest used by the working baseline.

- `manifests/ran/oai-nrue-configmap-live.yaml`  
  Captured/live NR-UE ConfigMap used by the working baseline.

- `manifests/ran/oai-nr-ue-deploy-live.yaml`  
  Captured/live UE1 deployment manifest used by the working baseline.

- `manifests/ran/oai-nr-ue-rfsim-svc.yaml`  
  RFsim service used by the UE / RFsim experiments.

## Multi-UE manifests

- `manifests/ran/multi-ue/oai-nr-ue-2.yaml`  
  UE2 deployment manifest.

- `manifests/ran/multi-ue/oai-nr-ue-3.yaml`  
  UE3 deployment manifest.

- `manifests/ran/multi-ue/oai-nr-ue-4.yaml`  
  UE4 deployment manifest.

- `manifests/ran/multi-ue/oai-nr-ue-5.yaml`  
  UE5 deployment manifest.

## Scripts

- `scripts/prepare-network.sh`  
  Recreates/sanitizes Multus network attachments for N2/N3.

- `scripts/deploy-core.sh`  
  Deploys the Open5GS core.

- `scripts/deploy-ran.sh`  
  Deploys the RAN side: gNB and UE resources.

- `scripts/validate-e2e.sh`  
  Validates the E2E baseline, including pod status and UE tunnel readiness.

- `scripts/ue/generate-5ue-manifests.sh`  
  Generates or updates multi-UE manifests.

- `scripts/ue/provision-5ue-subscribers.sh`  
  Provisions UE1-UE5 subscribers in Open5GS.

- `scripts/ue/uectl.sh`  
  Helper script for controlling UE deployments.

## Web dashboard

- `web-dashboard/README.md`  
  Dashboard-specific notes.

- `web-dashboard/requirements.txt`  
  Python dependencies for the Flask dashboard.

- `web-dashboard/run-dashboard.sh`  
  Starts the dashboard from inside the dashboard folder.

- `web-dashboard/app.py`  
  Main Flask dashboard application. Provides status, live metrics, and single-UE action APIs.

- `web-dashboard/multi_ue_api.py`  
  Multi-UE dashboard API. Handles UE inventory, desired UE count, per-UE start/stop/ping, and selected-UE scenario execution.

- `web-dashboard/templates/index.html`  
  Main dashboard UI template.

- `web-dashboard/static/app.js`  
  Dashboard frontend JavaScript helpers.

- `web-dashboard/static/style.css`  
  Dashboard styling.

## Dashboard action scripts

- `web-dashboard/actions/common.sh`  
  Shared shell helpers for dashboard actions.

- `web-dashboard/actions/ci_ownership.sh`  
  Checks serving gNB / UE ownership through OAI telnet CI commands.

- `web-dashboard/actions/collect_snapshot.sh`  
  Collects logs and runtime state snapshots.

- `web-dashboard/actions/validate_e2e.sh`  
  Dashboard action for E2E validation.

- `web-dashboard/actions/recover_ran.sh`  
  RAN recovery helper.

- `web-dashboard/actions/recover_full.sh`  
  Full lab recovery helper.

- `web-dashboard/actions/ho_a_to_b.sh`  
  Experimental A-to-B handover validation script. Do not treat as proven successful.

- `web-dashboard/actions/ho_b_to_a.sh`  
  Experimental B-to-A handover validation script. Do not treat as proven successful.

## Historical baseline evidence

- `docs/baselines/stable-e2e-before-ho-debug-20260503-101700/`  
  Historical stable baseline evidence captured before handover debugging. Keep for traceability.

## Local ignored files

These files are intentionally not tracked by Git:

- `web-dashboard.log`  
  Runtime dashboard log. Safe to truncate.

- `web-dashboard/.venv/`  
  Local Python virtual environment. Keep locally unless recreating the environment.

## Current project status

The stable 5-UE dashboard baseline is restored and validated.

The handover validation work is still experimental:

- gNB-B N2/N3/RFsim target connectivity was validated.
- Direct target-side service through gNB-B was validated during debugging.
- Seamless RFsim/N2 handover is not yet proven.
- The unsupported official neighbor/measurement ConfigMap block was rolled back.
- Handover scripts remain experimental and should not be used as proof of completed handover.
