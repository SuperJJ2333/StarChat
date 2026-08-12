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

## Environment availability and runtime smoke test

Docker Desktop is now available. The following command completed successfully:

```powershell
docker compose --env-file .env.example build business-api business-worker
docker compose --env-file .env.example up -d business-postgres business-redis business-api business-worker
```

Runtime results:

- `business-postgres`: healthy.
- `business-redis`: healthy.
- `business-api`: healthy on `127.0.0.1:8082`.
- `business-worker`: healthy heartbeat.
- `/api/v1/health/live`: HTTP 200.
- `/api/v1/health/ready`: HTTP 200 with database `ready`.
- PostgreSQL `alembic_version`: `0003_outbox_events`.
- PostgreSQL contains `idempotency_records` and `outbox_events`.
- In-container SQLAlchemy connectivity check: `database: True`.

The dedicated PostgreSQL pytest remains explicitly skipped unless
`RUN_POSTGRES_TESTS=1` is set; the live container smoke test and migration query
cover the currently available PostgreSQL environment.
