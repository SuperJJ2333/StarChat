# Wallet incident simple workflow verification

Approved design: `docs/superpowers/specs/2026-09-08-wallet-incident-simple-workflow-design.md`.
Implementation started September 8; production published September 9, 2026 (Hong Kong).

## Behavior and review

- One Chinese incident action orchestrates existing acknowledge, review and resolve commands. Fund restoration remains a separate authenticated, explicit confirmation with unchanged backend guards.
- Chinese descriptions distinguish original incident evidence, last full monitor result and current read-only source/coverage diagnostics. Missing historical reasons remain unknown. Technical identifiers are expandable.
- Incomplete monitor results retain the compatible error code and add allowlisted reason/status fields plus sanitized structured logs. No raw provider secrets enter logs or responses.
- Unknown outcomes retain original command journals and stop. Definite version conflicts have bounded refresh/reprepare. Credentials remain in memory and are cleared; one-time TOTP proofs are not reused.
- Exact manual-liquidity backing advisory classification is preserved. Current diagnostic snapshots cannot authorize fund restoration. A moving source snapshot returns WAITING instead of a false coverage conflict.
- Specification review preceded backend/frontend quality and security review. No blocking findings remained; the source-snapshot race observation was fixed and regression tested.

## Tests

- Test-first evidence: incomplete monitor fields and missing diagnostic route failed before implementation; source-advancement case failed before its consistency fix, then passed.
- Final rerun: `node --test --test-reporter=dot frontend/tests/*.test.mjs`: 109 passed.
- Final rerun: `py -3.12 -m pytest tests/business_api/wallet/test_manual_operations_api.py -q`: 27 passed.
- Full `scripts/verify.ps1` completed with `Verification: PASS`; log: `artifacts/2026-09-08/incident-simple/verify.txt`. Business suite: 1394 passed, 34 skipped; subsequent Flutter boundary suite: 66 passed. Final source-race regression was additionally covered by the focused rerun above.
- Existing dependency deprecations remain in the full log: Starlette/httpx test client and Getui Pydantic class configuration. They are outside this change; this record does not claim warning-free execution or that skipped cases ran.
- OpenAPI export/check and configuration/migration checks passed in full verification.
- CUA desktop browser exercised the synthetic fixture `frontend/tests/incident-simple-browser.html`: process sequence was ack/review/resolve, incident resolved while paused remained true. Separate confirmed restore produced resume and paused=false. These were synthetic API calls, not live financial operations. Desktop layout inspected; no mobile or remote Figma verification claimed.

## Production

- Release: `/opt/starchat/releases/incident-simple-20260909/`.
- Pinned previous API image: `sha256:7cf7f88cf5d07b27cae561f71961a76215ed166c97167029206ab8f25fe8bea6`.
- New API image: `sha256:8e2c7cf56d1e9509b01a285aad57510324945ee76ba2d8dac39440630c363ab7`.
- Only two API source files and five frontend files deployed. No database migration; worker and observer were not redeployed. Existing session fix is retained in the pinned base.
- Compose configuration equality asserted except the API image. Container health, both API source hashes and all frontend hashes passed. Nginx configuration check and reload passed.
- Direct HTTPS certificate-verified read-only checks passed: HTML and four JavaScript resources returned 200 with exact local hashes; captcha returned 200; anonymous overview and new diagnostics returned 401.
- Public evidence: `artifacts/2026-09-08/incident-simple/public-verified.json`; deployment orchestration: `artifacts/2026-09-08/incident-simple/release.py`.
- Server retains previous static files and image-only rollback: `python3 /opt/starchat/releases/incident-simple-20260909/release.py rollback`. Rollback logic preserves existing Compose environment and restores prior static files; rollback was not executed against the newly published service.
- No live incident processing, payment or fund recovery was performed. Administrator must invoke the two explicit actions with their own credentials.

Historical incomplete-review reason was not retained by the old API and remains unproven. The new version improves future evidence; it does not reconstruct missing historical facts.
