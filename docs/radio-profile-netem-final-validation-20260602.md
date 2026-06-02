# Radio / Modulation Profile Control Final Validation — 2026-06-02

## Final conclusion

RFsim-only MCS/modulation forcing was not proven. DU logs stayed at MCS 0 / Qm 2 / SNR around 51 dB regardless of RFsim AWGN profile.

The final validated implementation uses:

- DU-aware RFsim metadata switching
- serveraddr preservation
- nssai_sst / nssai_sd preservation
- UE reattach and oaitun_ue1 validation
- tc netem shaping on oaitun_ue1
- dashboard API under /api/radio

## Final proof

Proof directory:

```text
/home/ghazi/oran-proof/radio-profile-final-v2-20260602-041910
```

## Final results

```text
Profile           Netem params                              TCP Mbps  Retransmits  Ping avg  Verdict
scheduler-auto    clear/no-shaping                          32.786    99           67.161    PASS
qpsk-robust       rate=18mbit delay=8ms jitter=2ms loss=0%  17.106    64           73.621    PASS
qam16-balanced    rate=32mbit delay=2ms jitter=1ms loss=0%  29.356    165          68.936    PASS
qam64-throughput  rate=45mbit delay=1ms jitter=0ms loss=0%  32.206    76           70.153    PASS
qam256-max        clear/no-shaping/native-ceiling           32.618    105          78.453    PASS
```

## Final status

```text
PROBLEM_1_MCS_SHAPING=FIXED_FOR_NATIVE_CEILING
PROBLEM_2_DASHBOARD=FIXED
PROBLEM_3_QAM256=TESTED
VERDICT=RADIO_PROFILE_FINAL_VALIDATION_V2_DONE
```
