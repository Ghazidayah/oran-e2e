# O-RAN 5G Lab Dashboard

Start (from the repository root, so relative script paths resolve):

```bash
./run-web-dashboard.sh
```

Or directly from this directory:

```bash
cd web-dashboard
./run-dashboard.sh
```

Open:

```text
http://<lab-host>:18080
```

## Ports

The Flask port is **18080**, set in `app.py`. It is not configurable through the
environment: `PORT`, `HOST`, `PROJECT_ROOT` and `RUN_ROOT` are exported by the
launcher scripts but no Python module reads them.

`ORAN_DASHBOARD_PORT` is read by `mixed_du_handover_api.py` only, to build the
URL it calls back on. Setting it without also changing `app.py` desynchronises
the two: Flask stays on 18080 while the Mixed-DU handover module calls the port
you set. Leave it unset unless you change both.

## Environment variables actually read

| Variable | Read by | Default |
|---|---|---|
| `ORAN_REPO` | `mixed_du_handover_api.py`, `radio_profile_api.py`, `real_frequency_api.py` | repository root |
| `ORAN_LAB_IP` | `app.py` | `192.168.1.142` |
| `ORAN_RAN_NS` | `multi_ue_api.py` | `oran-ran` |
| `ORAN_DASHBOARD_PORT` | `mixed_du_handover_api.py` | `18080` |
| `ORAN_DASHBOARD_SELF_URL` | `mixed_du_handover_api.py` | `http://127.0.0.1:18080` |
| `TRAFFIC_API_HOST` / `TRAFFIC_API_PORT` | `scripts/traffic/traffic_api_server.py` | `0.0.0.0` / `5055` |

Note that `app.py` derives its own paths from `Path.home() / "oran-e2e"` and
`Path.home() / "oran-proof"`; these are not overridable. Cloning the repository
under a different directory name requires editing `app.py` lines 15-16.
