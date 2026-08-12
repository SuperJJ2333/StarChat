# 2026-08-12 Support, CAIBI Ledger and Red Packet Verification

- Full verification: `60 passed, 1 skipped`; Matrix bot `8 passed`; repository/deployment/OpenAPI/Compose checks PASS.
- PostgreSQL runtime upgraded successfully to `0008_caibi_red_packets (head)`.
- Docker `business-api` rebuilt from main and reached `healthy`.
- Live endpoint returned `{"ok":true,"service":"六合通 Business API"}`.
- Ledger assertions cover zero-sum entries, non-negative user balances, exact 0.5% HALF_UP fee with 0.01 minimum, replay safety and payload mismatch rejection.
- Adjustment assertions cover user scope, single/day limits, finance review, large-value administrator approval and execution.
- Red packet phase started with exact equal/random allocation, single claim, expiry refund and abnormal cancellation tests.
