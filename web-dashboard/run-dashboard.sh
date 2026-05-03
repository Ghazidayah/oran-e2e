#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv .venv
. .venv/bin/activate
pip install -q -r requirements.txt
export PROJECT_ROOT="${PROJECT_ROOT:-$HOME/oran-e2e-freeze}"
export RUN_ROOT="${RUN_ROOT:-$HOME/oran-proof}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-18080}"
python app.py
