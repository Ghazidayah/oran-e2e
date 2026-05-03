# Stable E2E Baseline Protected

Baseline ID: stable-e2e-before-ho-debug-20260503-101700  
Date: 2026-05-03T10:25:52+01:00  
Recovery evidence root: /home/ghazi/oran-proof/protect-baseline-recovery-20260503-101700  
Working directory: ~/oran-e2e-freeze  

## Result

Status: PASS  
validate-e2e exit code: 0  

## Validated state

- Core pods Running.
- RAN pods Running.
- UE tunnel oaitun_ue1 present.
- UE IPv4: 10.45.0.2/24.
- Ping to DN gateway 10.45.0.1 succeeded with 0% packet loss.
- Ping to 8.8.8.8 via oaitun_ue1 succeeded with 0% packet loss.
- AMF logged Registration complete for imsi-999700000000001.
- SMF created session on DNN oai with IPv4 10.45.0.2.
- validate-e2e.sh completed with validate_exit=0.

## Important note

This is a clean E2E attach/session/user-plane baseline.  
It is not a successful N2 handover proof.

The UPF IPv6 Invalid packet messages are known residual noise and are not blocking this IPv4 E2E validation.

## Recovery command

To return to this state after reboot or shutdown:

```bash
cd ~/oran-e2e-freeze
./scripts/prepare-network.sh
./scripts/deploy-core.sh
./scripts/deploy-ran.sh
sleep 180
timeout 300 ./scripts/validate-e2e.sh
```
