# Phase 2 Dashboard Realistic Scenarios Validation

## Result

The real dashboard on port 18080 was updated to replace the old/basic traffic cards with Phase 2 realistic traffic scenarios.

## Dashboard URL

http://192.168.1.142:18080

## Traffic API URL

http://192.168.1.142:5055

## Validated dashboard/API jobs

| Scenario | Job ID | Status |
|---|---|---|
| Run All Realistic Traffic | 20260525-031303-run-all-54f5c0 | OK |
| Image Download | 20260525-031153-image-3ce06a | OK |
| Web Browsing | 20260525-030926-web-82699d | OK |
| Streaming-like HLS | 20260525-030912-streaming-1dc0b9 | OK |

## Dashboard scenarios now available

- Image Download
- iperf3 TCP Throughput
- UDP Jitter / Loss
- Video Download
- Web Browsing
- Streaming-like HLS
- Run All Realistic Traffic

## Evidence location

Traffic API job evidence:

~/oran-proof/phase2-traffic-api/

Scenario proof evidence:

~/oran-proof/phase2-realistic-traffic/

Full suite evidence:

~/oran-proof/phase2-realistic-traffic-suite/

## Conclusion

The Phase 2 realistic traffic scenarios are now integrated into the real dashboard and can be launched from the web UI.
