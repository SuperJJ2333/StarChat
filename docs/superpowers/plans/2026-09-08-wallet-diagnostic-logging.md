# Wallet diagnostic logging implementation plan

Status: approved design; user explicitly requested implementation on 2026-09-08.
Goal: preserve actionable, redacted request failure causes and correlate them with wallet incidents.
Architecture: standalone standard-library diagnostic module in the existing TRON package; JSON stderr; existing SQLAlchemy transaction events for commit-only evidence. Existing business responses and financial predicates remain intact.
Execution: sequential in current workspace; preserve existing edits using the scoped before snapshot under docs/verification/artifacts/2026-09-08/wallet-diagnostics/.

- [x] Add failing tests in tests/business_api/tron/test_diagnostics.py for request classification, redaction, levels, context isolation, and sink failure; add transaction and stale-source diagnostics tests.
- [x] Run `py -3.12 -m pytest tests/business_api/tron/test_diagnostics.py -q` with the repository Python paths and record the intended red result.
- [x] Implement diagnostics.py, reader request instrumentation and observer/CLI lifecycle. Preserve outward exceptions, status JSON fields and SQLite schema.
- [x] Instrument funding source ages and monitor trace boundaries; register commit-only incident/control events with rollback and savepoint coverage. Add alert transport outcome diagnostics.
- [x] Wire isolated INFO/DEBUG configuration into API, Worker and watch CLI; set 20m × 10 Docker rotation and provide restricted pre-deployment archive/retention tooling.
- [x] Run focused TRON, wallet, Worker and infrastructure tests; run scripts/verify.ps1, record all outcomes. Review specification first, then security/quality. Verify source exception text, addresses and credentials cannot enter logs.
- [x] Prepare a production release preserving the actual Compose overlays, image IDs and mount configuration; archive selected logs before replacement, verify deployed source/config and live redacted diagnostics, document rollback.
- [x] Update runbooks and verification evidence; distinguish deployed logging from independently authorized wallet recovery.

File ownership is the list in the approved design plus API startup, manual control commit logging, wallet alert email diagnostics, tests and archive/release tooling. No schema migrations, new public API fields, threshold changes or financial state transitions are planned.
