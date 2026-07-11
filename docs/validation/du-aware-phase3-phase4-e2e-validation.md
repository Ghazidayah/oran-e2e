# DU-Aware Phase 3 / Phase 4 / E2E Validation

Date: 2026-05-30

## Goal

Make Phase 3, Phase 4, End-to-End validation, and single-UE realistic traffic scripts safe in the Mixed-DU architecture.

## Design rule

The runtime scripts must use the exact protected UE:

```text
deployment: oai-nr-ue
configmap:  oai-nrue-config
role:       protected ue1
```

They must not use loose pod matching such as:

```bash
awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}'
```

because that can accidentally select `ue2`, `ue3`, `ue4`, or `ue5`.

## DU-aware behavior

Slice switching changes only:

```text
nssai_sst
nssai_sd
```

It must preserve:

```text
serveraddr
```

So `ue1` can stay on its current DU target while the slice changes.

## Validated result

```text
serveraddr=oai-du0-rfsim
slice=nssai_sst=1 nssai_sd=0xffffff
VERDICT=DU_AWARE_SLICE_SWITCH_OK
VERDICT=PROTECTED_UE1_CURRENT_SLICE_VALIDATED
VERDICT=E2E_UE1_VALIDATION_OK
VERDICT=UE_COMMON_SLICE_HELPER_FIXED
```

## Runtime scripts updated

```text
scripts/ue/ue-common.sh
scripts/slicing/switch-ue-slice.sh
scripts/slicing/validate-current-slice.sh
scripts/slicing/apply-slice-resource-profile.sh
scripts/validate-e2e.sh
scripts/traffic/run-image-download.sh
scripts/traffic/run-web-browsing.sh
scripts/traffic/run-streaming-like.sh
scripts/traffic/run-video-download.sh
scripts/traffic/run-iperf-tcp.sh
scripts/traffic/run-udp-traffic.sh
```

## Warning

Do not rerun the old generator script `scripts/slicing/apply-real-snssai-slicing.sh` until it is patched,
because it can regenerate older non-DU-aware runtime scripts.
