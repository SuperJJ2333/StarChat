# Wallet design hardening and offline Sandbox plan

> Execute sequentially using executing-plans; no delegation is needed.

**Authorization:** User requested continuing design and Sandbox verification without a custody provider on 2026-09-06. This authorizes the bounded offline work below, not production activation or approval of ADR-0010.

**Goal:** Resolve the review findings in a normative design supplement and execute an independent, deterministic financial model against fault scenarios.

**Architecture:** Python standard-library model with transactional SQLite ledger and a separate simulated custody store. No network, production imports, credentials, real addresses, migrations or frontend changes. Model results are not evidence of PostgreSQL or actual custody correctness.

**Owned files:** The original wallet spec and ADR-0010; `docs/superpowers/specs/2026-09-06-wallet-safety-supplement.md`; this plan; `docs/verification/artifacts/2026-09-06/wallet-sandbox/`; `docs/verification/2026-09-06-wallet-sandbox.md`.

- [x] 1. Specify reserve accounting, issuance, legacy migration, indirect transfer risk, finality, cancellation, recovery, monitoring, reports and mobile acceptance. Preserve production approval gates.
- [x] 2. Write `test_wallet_model.py` before the executable model. Assert roundtrip precision, underfunding, atomic rollback, idempotency, finality, nonnegative holds, timeout recovery, pause-before-submit, missing local orders and reporting.
- [x] 3. Run unittest and preserve the expected red output. Implement `wallet_model.py`, rerun until green. Tests exercise a proposed model, not the existing application.
- [x] 4. Run existing wallet regression tests without provider participation and the repository `scripts/verify.ps1`. Save outputs; identify pre-existing or environmental failures without suppressing them or expanding into unrelated fixes.
- [x] 5. Perform specification-compliance then quality/security self-review; record exact tested and untested scope and reproduction commands. Review git diff and leave changes uncommitted.

**Result:** 23 model tests pass, 7/7 in-memory safety-control mutations caught, 15 existing wallet regressions pass, repository verify exits 0 with 468 passes / 19 skips and existing deprecation warnings. Ruff unavailable. Full evidence and exclusions: `docs/verification/2026-09-06-wallet-sandbox.md`. This completes the bounded design/model plan, not production implementation.

**Reproduction:** From the repository root, use PowerShell 7 with UTF-8 encodings and `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`. Run `python -B -m unittest discover -s docs/verification/artifacts/2026-09-06/wallet-sandbox -p test_wallet_model.py -v`. SQLite is in-memory, so no runtime database leaves the artifact directory. Capture output with explicit UTF-8 encoding.
