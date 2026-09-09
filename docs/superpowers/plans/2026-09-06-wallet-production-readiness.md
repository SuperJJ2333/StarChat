# Wallet production deployment readiness

> Use subagent-driven-development with test-first fixes and domain then security review. User authorized continuing until deployment is correct; retain the existing approved no-provider and real-money-disabled boundary.

**Goal:** Prove a reproducible application release can migrate and start with production settings, preserve existing data, and roll back application code safely without opening unsupported funding paths.

**Architecture:** Repair the historical duplicate cover column migration without dropping existing data. Exercise full PostgreSQL history on fresh and previously populated schemas. Produce immutable API/Worker images, explicit production configuration checks, and a deployment/restore rehearsal. Read-only inspection of the authorized server determines its actual baseline; no secrets or production dumps enter repository evidence.

**Tech stack:** PostgreSQL 16, Alembic, FastAPI, Python 3.12, Docker Compose, PowerShell 7.

## Tasks / ownership

- [x] Migration agent owns `migrations/versions/0025_moment_drafts_native_ads.py` and new `tests/business_api/test_production_migration_chain.py`. Reproduce full `command.upgrade(config,'head')` in isolated PostgreSQL (currently 0014 creates cover_url, 0025 adds it again). Replace duplicate addition with safe compatibility DDL that preserves an existing column and adds a missing legacy column. Downgrade must not remove a column owned by0014. Test fresh-to-head, upgrade with preserved existing data, repeat head, and offline SQL. Report other historical failures rather than stamping over them.
- [x] Root owns deployment config/preflight tests/scripts and any confirmed Docker startup fix; inspect actual production baseline read-only with SSH. Check image versions, migration ordering, health, non-placeholder secrets without printing values, funds-disabled behavior and rollback feasibility. Diagnose missing access locally before requesting user intervention.
- [x] Root builds API/Worker from the reviewed source, records image IDs/digests and dependency versions, rehearses full upgrade/start with synthetic production settings and isolated databases. Verify database readiness, wallet refusal, monitor unavailable visibility, restart/recovery and backup restore using synthetic data only.
- [x] Add a concrete reviewed runbook and production readiness report under `docs/runbooks/` and `docs/verification/`; evidence only `docs/verification/artifacts/2026-09-06/wallet-production-readiness/`. Do not copy live environment values or keys. Explicitly separate application deployability from unavailable real custody/MFA/external-delivery requirements.
- [x] Domain review, security review, focused tests and `pwsh -NoProfile -File scripts/verify.ps1` pass. Correct blockers uncovered by actual tests. Do not claim real-money production launch, independent RPO=0 or external notification delivery from a local rehearsal.

## Verification commands

PowerShell UTF-8 initialization precedes every command. Python uses `py -3.12`, `PYTHONPATH=services/business-api;services/business-worker/app;.`. Local isolated PostgreSQL is the existing loopback fixture; each test owns a random schema and may drop only that synthetic schema. Never reset real schemas. Test new chain via `py -3.12 -m pytest tests/business_api/test_production_migration_chain.py -q`; build via Docker using explicit dated release tags; inspect only safe image/dependency metadata. Any live deployment requires the fully prepared source manifest, tested migrations, existing-volume backup location and rollback commands first.
