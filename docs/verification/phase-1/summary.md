# 六合通 Phase 1 Verification Summary

Date: 2026-08-12  
Branch: `feature/phase-1-business-core`

## Scope

Phase 1 establishes only the business-service foundation: product/asset naming,
FastAPI configuration and health routes, stable errors and trace IDs, SQLAlchemy
and Alembic, durable idempotency records, transactional Outbox, a bounded Worker,
Compose wiring, and a versioned OpenAPI contract. It intentionally exposes no
ledger balance, transfer, red-packet, support, wallet, deposit, or withdrawal API.

## TDD red evidence

Each implementation slice was first exercised with a failing focused test:

- API health/config: missing `app.core.config`.
- Database foundation: missing `app.core.database`.
- Stable errors/tracing: missing `app.core.errors`.
- Idempotency: missing `app.core.idempotency`.
- Transactional Outbox: missing `app.core.outbox`.
- Worker dispatch: missing `services/business-worker/app/worker.py`.
- OpenAPI: missing `scripts.export_openapi` and committed contract.
- Configuration isolation regression: unscoped `DATABASE_URL` incorrectly affected
  the business service before `BUSINESS_` namespace enforcement was added.

## Green evidence

Command:

```powershell
pwsh -NoProfile -File scripts/verify.ps1
```

Result:

```text
Repository policy: PASS
Deployment policy: PASS
TemplateTools: PASS
Configuration rendering complete.
8 passed in 0.77s
22 passed, 1 skipped in 0.66s
Business API import: PASS
AST parse: PASS (25 files)
Alembic migrations: PASS
OpenAPI contract: PASS
Verification: PASS
```

Additional verified properties:

- `docker compose --env-file .env.example config --quiet` succeeds.
- Alembic has exactly one head: `0003_outbox_events`.
- Alembic consumes only the namespaced `BUSINESS_DATABASE_URL` override.
- Offline PostgreSQL SQL generation succeeds from base through the current head.
- `scripts/export_openapi.py --check` reports no contract drift.
- The committed contract contains only `/api/v1/health/live` and
  `/api/v1/health/ready`.

## Environment availability

- Docker CLI is installed, but the Docker Desktop Linux daemon was unavailable:
  `npipe:////./pipe/dockerDesktopLinuxEngine` did not exist. Image builds and
  runtime container health were therefore not executed in this verification run.
- The PostgreSQL integration test remains explicitly skipped unless
  `RUN_POSTGRES_TESTS=1` is set. SQLAlchemy behavior was tested with SQLite and all
  PostgreSQL migrations were validated in Alembic offline mode.

These two environment-dependent checks remain deployment gates; they do not cause
fallback to floating images, an alternate database, or unversioned migrations.
