# Wallet reporting implementation plan

> **For agentic workers:** Use subagent-driven-development for implementation and specification review followed by quality/security review.

**Goal:** Deliver the next approved reporting slice: authorized daily ledger previews with exact per-account opening/increase/decrease/closing, transaction evidence and safe CSV export. Financial posting rules remain unchanged.

**Authorization:** User requested continuation after MI 6 acceptance. This executes the existing safety supplement §7; provider-free Sandbox and production funding-disabled constraints persist. No new financial rights or release authority is introduced.

**Architecture:** Read both append-only ledgers in one database snapshot through public read interfaces. Hong Kong calendar days map to UTC half-open windows. Include every account, including platform and held/escrow accounts, so individual transaction imbalance cannot hide behind offsetting errors. A returned immutable response includes source entry IDs and a deterministic SHA256 content digest. The endpoint is explicitly a draft preview, not a persisted close or independent audit archive: late committed/backdated entries can change a later preview. No fake cutoff sequence or finalization claim.

**Tech Stack:** Python 3.12, SQLAlchemy, FastAPI, Decimal, pytest, PostgreSQL and SQLite tests.

## Ownership and tasks

- [x] Reporting implementer owns new `app/modules/wallet/reporting.py`, public ledger read helper if needed, and `tests/business_api/wallet/test_wallet_reporting.py`. Root owns admin API wiring, API tests, OpenAPI, docs. No Flutter changes or new APK required.
- [x] Test RED: seed dated balanced USDT and CAIBI postings through real ledger APIs; assert Hong Kong midnight boundaries, held/platform inclusion, exact opening + net = closing, six/two decimal formatting, transaction-level imbalance detection, bounded refusal on oversized evidence, deterministic digest, CSV formula neutralization.
- [x] Implement `WalletReportService(factory).daily(day: date)` with keys `day`, `timezone`, `start`, `end`, `finalized: false`, `accounts`, `entries`, `integrity`, `digest`. Reject future dates and invalid limits, use transaction snapshot semantics. Each entry has ID, transaction ID, account, asset, signed amount, UTC time, reason and scope. Each account has asset/account/opening/increase/decrease/closing. Use decimal strings, no addresses/keys/messages.
- [x] Implement `to_csv(report)` with metadata/digest, stable rows and neutralization of untrusted cells beginning with formula/control characters. Never silently truncate a report; cap total evidence to 100,000 entries and fail explicitly.
- [x] Root API RED: unauthenticated 401, ordinary user 403, finance role allowed, date 422, JSON/CSV precision and audit evidence. Add GET `/api/v1/admin/wallet/reports/daily?day=YYYY-MM-DD&format=json|csv`, existing FINANCE_REVIEW permission (SYSTEM_ADMIN also allowed), audit read/export success with digest; no provider required. Errors are stable 422/413. CSV attachment filename uses validated ISO date and all responses use no-store.
- [x] Run focused tests, spec review then security review, fix findings. Export/check OpenAPI and run scripts/verify.ps1. Save evidence only under `docs/verification/artifacts/2026-09-06/wallet-reporting/`.
- [x] Update runbook and verification document with exact semantics and remaining scope: durable cutoff-pinned final close, incident ACK/escalation/delivery, provenance and provider/DR still pending. Never present a preview as final close or real custody reconciliation.

## Acceptance examples

For Hong Kong 2026-09-06, start=2026-09-05T16:00:00Z and end=2026-09-06T16:00:00Z. Entries exactly at start are period movement; at end are excluded. Prior 10 USDT + current 2 USDT - current 1 USDT gives closing 11.000000. Two individually unbalanced transactions with net zero must still set integrity false. An account named `=SUM(1,1)` must export as inert text. Same captured entries produce the same digest; a new preview after a late entry may legitimately differ and remains finalized=false.

Commands: `$env:PYTHONPATH='services/business-api;.'; py -3.12 -m pytest tests/business_api/wallet/test_wallet_reporting.py tests/business_api/test_wallet_reporting_routes.py -q`, then `pwsh.exe -NoProfile -File scripts/verify.ps1`.

**Completion evidence:** Focused26 PASS; SQLite+isolated PostgreSQL30 PASS; scripts/verify.ps1 PASS (524 passed,21 skipped); OpenAPI check PASS; domain then Quality/Security review PASS. Error no-store reviewer finding resolved in app/core/errors.py, covered red/green. No financial posting or UI/APK changes. See docs/verification/2026-09-06-wallet-reporting.md.
