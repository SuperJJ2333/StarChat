# Wallet incident simple workflow implementation plan

Approved design: `docs/superpowers/specs/2026-09-08-wallet-incident-simple-workflow-design.md`.

Goal: one understandable incident-processing action, separate guarded fund recovery, explicit diagnostic reasons, without weakening existing financial/authentication transitions.

- [x] Backend: reproduce loss of monitor reason in `tests/business_api/wallet/test_manual_operations_api.py`; add allowlisted error fields and structured review-result logging in `services/business-api/app/api/manual_wallet_operations.py`. Preserve existing error code and authorization. Inspect existing monitor snapshot sources and expose safe current check information if possible without running mutations during reads.
- [x] Frontend: add independently testable workflow/presentation module and tests; integrate into `frontend/src/admin-manual-wallet-panel.js`. Show Chinese incident summary, times, impact, current state and expandable technical detail. One process form with reason codes internally supplied; operation-password mode handles ack/review/resolve sequentially with latest versions and per-step idempotency. TOTP mode must obtain a fresh proof each step rather than reuse one-time codes.
- [x] Preserve unknown-result journals, stop on unknown outcomes, refresh/reprepare only definite version conflicts with a bound. No implicit financial recovery. Separate restore form uses a fixed auditable reason rather than user-entered internal code.
- [x] Verify specific monitor reason display, state progression, no repeat after success, unchanged pending keys, safe credential clearing, multi-incident blockers and advisory handling. Maintain existing payout behavior.
- [x] Review specification then quality/security; run frontend and focused backend tests, full verify, update API description/runbook/local UI registry as applicable.
- [x] Build pinned one-scope release, retain rollback, deploy under existing production authorization, verify public resources and API health, record evidence. Do not execute user's incident processing or fund recovery on their behalf.

File ownership: root owns backend API/tests, docs and release files; delegated frontend worker owns panel/new workflow module and relevant frontend tests. Reviewer is read-only. Current workspace contains ongoing approved deployments and unrelated changes, so preserve it and do not reset, broadly stage, or introduce a divergent worktree copy.
