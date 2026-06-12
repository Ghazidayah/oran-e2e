# O-RAN E2E Freeze Pack

## Order
1. ./scripts/prepare-network.sh
2. ./scripts/deploy-core.sh
3. ./scripts/deploy-f1-ran.sh
4. ./scripts/validate-e2e.sh

## Expected result
- AMF bound on 10.10.0.101:38412
- UPF bound on 10.20.0.101:2152
- gNB strategy = Recreate
- UE gets oaitun_ue1 with 10.45.0.x
- default UE route goes through oaitun_ue1
- ping via oaitun_ue1 to 8.8.8.8 succeeds
