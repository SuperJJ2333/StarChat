# Logical conversation client — final verification

Baseline 8051edb5; isolated branch codex/conversation-reliability-20260919. This is source verification, not APK/device delivery. User authorized ADR and production repair. Windows / PowerShell 7 / Flutter 3.44.9 / Dart 3.12.2 / Python 3.12. Dependencies resolved offline with the existing lock; the test-only wakelock interface is pinned at 1.7.0.

## Evidence accounting

All paths below are relative to [artifact directory](artifacts/2026-09-19/conversation-reliability/). Raw source/lock hashes: [final-source-sha256.json](artifacts/2026-09-19/conversation-reliability/final-source-sha256.json). No secrets or production IDs are included in that manifest.

| Gate | Command and actual result | Evidence |
| --- | --- | --- |
| Full client, final broad run | flutter test --no-pub --reporter expanded: exit 1; 3542 passed, one cache-fixture path failure | flutter-full-final.log |
| Remaining failure and final guards | flutter test for moment_media_cache_test, canonical_send_guard_test, offline_send_state_test: exit 0, 39 passed | cache-sdk-anchor-focused.log |
| Static analysis | flutter analyze --no-pub: exit 0, no issues | flutter-analyze-final.log |
| Mobile boundaries | Python pytest tests/mobile: exit 0, 70 passed | mobile-boundary-final.log |
| Full repository initial gate | pwsh -NoProfile -File scripts/verify.ps1: exit 1 at business tests; 2094 passed, 58 skipped, one obsolete migration-head assertion | verify.log |
| Corrected migration expectation | py -3.12 -m pytest tests/business_api/test_wallet_release_baseline.py -q: exit 0, 2 passed | migration-baseline-final.log |
| Remaining unchanged repository gates | pwsh -NoProfile -File artifact/verify-remaining.ps1: exit 0, Verification: PASS | verify-remaining.log |
| Offline dependency consistency | flutter pub get --offline: exit 0, locked version preserved | pub-get-final.log |
| Whitespace | git diff --check: exit 0 | diff-check.log |

This is composite acceptance evidence, not a claim that the initial monolithic command exited zero. The only business failure asserted old head 0069; it now requires 0070 with parent 0069. No backend executable input changed afterward. Remaining script gates (mobile, UI drift, import/AST, unique migration head/offline SQL, OpenAPI, Compose rendering) were executed unchanged with the correct worktree root. Per the delivery workflow's evidence reuse rule, the 20-minute unchanged backend suite was not repeated.

The last full Flutter failure reproduced independently: a Windows scratch path retained '..', making the raw directory-enumeration path 268 characters. Normalizing the fixture shortens it to 242; production cache is unchanged. All original cache assertions remain, and the 39-case rerun includes the last SDK exact-member completeness and unknown-anchor regressions. Unchanged full-suite passes are reused instead of a third equivalent run.

Warnings are accounted for: the existing local Python stack emitted Starlette/httpx and Pydantic class-config deprecations; no warning was silenced or new runtime dependency introduced. The backend's 58 skips remain skips, not successful integration coverage. Relevant PostgreSQL concurrency and Synapse alias behavior were separately exercised against isolated actual production-compatible services; see server evidence.

## Red/green and review

Tests added before fixes cover association loss and cross-device restoration, merged source events/receipts, room navigation reuse and replacement rollback, claim/create response loss, exact peer/encryption/alias verification, canonical send refusal, stable outbox handoff, late completion and timeout recovery, account switching, red-bubble reconciliation and missing anchors. Initial failures and subsequent focused results were observed during implementation; full-run fixture failures remain in flutter-full.log, and regression outputs in client-focused-final.log / receipt-focused.log. Do not interpret fake UI tests as real-device delivery proof.

Specification review preceded quality/security review. Review corrections closed legacy unchecked publication, cross-room resend, account/lease races, incomplete-member sends, dropped visible receipts, duplicate pending routes, background status feedback, and failed replacement rollback. Final independent client specification review found no further blocker. Backend production overlay review verified only the two prior deployed friendship fixes were preserved outside this branch's changes.

## Boundaries and next step

One logical page combines accessible joined source rooms and keeps source event identity, media/receipts and keys intact. New text is durable before authority lookup and is dispatched only after canonical/account/relationship/encryption/member checks. Offline history opening does not depend on those send checks. All waitingNetwork/failed text states show failure feedback.

No claim of universal exactly-once delivery or zero physical duplicate rooms is made. Old bound/uncertain source transactions are not moved; inaccessible or left history is not force-joined; media kill-process durability is not implemented. Actual two-device/offline/cold-start/process-restart acceptance and a rebuilt/signed client release remain. Production server is already deployed and repaired independently; see [server evidence](2026-09-19-direct-room-v2-server.md).
