# Root additive integration — 2026-09-10

Transferred 129 source/document files from the original-root snapshot into the integration worktree. Exact paths: `artifacts/2026-09-10/main-integration/root-additive-transfer.json`.

Preserved release Moments CSS tokens and added admin/wallet tokens. Preserved release manual-wallet explicit gates and verified handover/observer mounts; updated imported historical compose tests to assert these safeguards. Preserved release wallet preflight. Added `.worktrees/` to Docker context exclusions.

Changed the enterprise-download test to validate the page’s HTTPS manifest link against generated Nginx fixture routes, independent of ignored deployed plist/IPA files and historical build numbers.

## Verification

- Scoped Node frontend/admin suite: 98 passed, 0 failed.
- Scoped Python infra, dedup, loadtest, compose, diagnostic and enterprise route suite: 68 passed in 4.78 seconds.
- Python used a test-process-only `scripts` namespace bootstrap because the global Python installation contains an unrelated `site-packages/scripts` package. No application import behavior was changed.
- One prior combined run observed a local HTTP retry test socket failure; isolated rerun and final combined 68-test run passed. No production retry logic was changed.
- All 129 manifest paths exist; environment example matches source snapshot; release Moments and added admin tokens coexist.

No staging or commits performed. Full project verification and browser/device acceptance belong to the integrating parent task.

## Concurrent root task follow-up

A separate active task updated original-root media reports and relocated wallet compose overlays to `infra/compose/`. This agent did not modify original root. Preserved its ten newer documents/tests under `artifacts/2026-09-10/main-integration/root-post-snapshot/`; original root-source-snapshot remains untouched.

Integrated the six newer documents and path-only changes to four tests. Added the five `infra/compose/` overlays from integrated source, preserving explicit funds gates and both protected read-only mounts; root-level paths remain compatible. Relocation suite: 12 passed in 1.46 seconds. Runtime capacity figures are preserved reports from that task, not independently reproduced here.

## Nonmobile specification-compliance review

No required correction found in the reviewed conflict merges:

- Migration `0060_merge_release_parity` has no data/schema operations and joins `0059_chat_payment_pin` with `0041_merge_mobile_parity`. AST graph audit finds exactly one head, `0060_merge_release_parity`; direct-room and moments branch migrations remain single revisions despite diamond ancestry.
- Admin API, admin-session boundary, CAPTCHA implementation and token service match release 2077 byte-for-byte. ADR-0055 CAPTCHA and ADR-0059 independent 48-hour administrator session protections remain present.
- Ordinary password login adds optional `matrix_user_id` via a dedicated `PasswordLoginResponse`, retaining thread-offloaded authentication, token issuance and audit. Dedicated admin login/refresh response models and secure HttpOnly SameSite=strict cookies remain intact; no admin privilege is derived from Matrix identity.
- AppError retains `Cache-Control: no-store` while adding optional `Retry-After`; validation/HTTP/unhandled errors retain no-store.
- Release preflight pins the new explicit migration head and still rejects enabled conversions, legacy real funds, independent deposits/payout requests/payout execution and a funding provider. Its readiness claim remains explicitly funds-disabled.

Review is source/specification compliance, not a substitute for the parent task’s currently running backend and migration execution tests. No service files were edited by this agent.

## Quality/security review (after specification review)

No blocking finding in reviewed nonmobile changes.

- Full frontend `npm test`: 115 passed, zero failures.
- `python scripts/verify_ui_contract.py`: PASS, 19 components and 331 screens.
- Repository and deployment PowerShell policy checks: PASS.
- Bounded proposed-change scan checked 307 UTF-8 text files, finding no private-key headers, JWT literals, real-format TRON addresses or AWS access key literals. No proposed filenames matched runtime databases, signing stores, APK/IPA files or verification artifact paths. This is a pattern-based check, not a guarantee against every secret encoding.
- Rendered complete root-overlay and relocated-overlay Docker Compose JSON with isolated relative observer/handover paths. Full JSON objects match exactly. Both API and worker retain read-only mounts with `create_host_path: false`; relative sources resolve from the first/base compose directory.
- Independent admin sessions and current-account checks remain in the frontend; tests cover failed mutation non-replay, credentials cleared/not persisted, permission denial distinction and stale refresh identity protection.
- Earlier migration graph review remains applicable; parent owns fresh backend/migration execution verification. No additional backend run or service edits performed here.

Root-level compose aliases intentionally remain byte-identical to relocated copies for existing commands; future changes should update both together or explicitly retire aliases in a separately reviewed cleanup.
