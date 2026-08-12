# 六合通 Business Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first product-grade FastAPI business service for 六合通, with branding/asset contracts, health endpoints, PostgreSQL migrations, stable errors, idempotency, transactional Outbox, a worker process, and versioned OpenAPI contracts.

**Architecture:** The business service is a modular monolith separate from Matrix Synapse. The first slice contains only platform infrastructure and shared contracts; no user balances, support permissions, red packets, or wallet operations are implemented until their dedicated phase plans. All write primitives are designed to support the later immutable CAIBI/USDT ledger.

**Tech Stack:** Python 3.12, FastAPI, Pydantic Settings, SQLAlchemy 2, Alembic, psycopg 3, PostgreSQL 16, Redis 7, pytest, OpenAPI.

## Global Constraints

- Product display name is `六合通`; internal identifier is `liuhetong`.
- Point display name is `彩币`; internal asset code is `CAIBI`; CAIBI has two decimal places.
- USDT has six decimal places; all asset arithmetic uses `Decimal`/`NUMERIC`, never float.
- Matrix remains a separate E2EE communication domain; this service never accepts or stores user message plaintext.
- No endpoint in this phase changes a balance or invokes a custody provider.
- Every future financial write must use an idempotency key, stable error code, actor, reason code, audit event, and transactional Outbox.
- Database migrations are forward-only and must be tested against a real PostgreSQL service before production.
- This branch is a real Git worktree; each task ends with a small conventional commit.

---

### Task 1: Brand and Service Contract Baseline

**Files:**
- Create: `services/business-api/pyproject.toml`
- Create: `services/business-api/app/__init__.py`
- Create: `services/business-api/app/core/__init__.py`
- Create: `services/business-api/app/core/branding.py`
- Create: `tests/business_api/test_branding.py`
- Modify: `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`
- Modify: `docs/superpowers/plans/2026-08-12-starchat-master-implementation-roadmap.md`

**Interfaces:**

```python
PRODUCT_NAME = "六合通"
PRODUCT_SLUG = "liuhetong"
CAIBI_ASSET_CODE = "CAIBI"
CAIBI_DISPLAY_NAME = "彩币"
CAIBI_SCALE = 2
USDT_ASSET_CODE = "USDT_TRC20"
USDT_SCALE = 6
```

- [ ] **Step 1: Write the failing branding test**

```python
from app.core.branding import (
    CAIBI_ASSET_CODE,
    CAIBI_DISPLAY_NAME,
    CAIBI_SCALE,
    PRODUCT_NAME,
    PRODUCT_SLUG,
    USDT_ASSET_CODE,
    USDT_SCALE,
)


def test_public_and_internal_product_contract_is_stable() -> None:
    assert PRODUCT_NAME == "六合通"
    assert PRODUCT_SLUG == "liuhetong"
    assert CAIBI_ASSET_CODE == "CAIBI"
    assert CAIBI_DISPLAY_NAME == "彩币"
    assert CAIBI_SCALE == 2
    assert USDT_ASSET_CODE == "USDT_TRC20"
    assert USDT_SCALE == 6
```

- [ ] **Step 2: Run the test and verify the missing module failure**

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
py -3.12 -m pytest tests/business_api/test_branding.py -q
```

Expected: collection fails because `services/business-api/app/core/branding.py` does not exist.

- [ ] **Step 3: Add the minimum branding constants and packaging metadata**

`branding.py` must contain only the constants above and no environment or database side effects. `pyproject.toml` must define package metadata, Python `>=3.12,<3.13`, runtime dependencies, and pytest configuration with `pythonpath = ["app"]`.

- [ ] **Step 4: Run the branding test**

Expected: one test passes with no warnings.

- [ ] **Step 5: Commit**

```powershell
git add services/business-api tests/business_api docs/superpowers
git commit -m "feat: establish liuhetong business contracts"
```

### Task 2: Configuration and Application Factory

**Files:**
- Create: `services/business-api/app/core/config.py`
- Create: `services/business-api/app/main.py`
- Create: `services/business-api/app/api/__init__.py`
- Create: `services/business-api/app/api/health.py`
- Create: `tests/business_api/test_health.py`

**Interfaces:**

```python
class Settings(BaseSettings):
    app_name: str = Field(default="六合通 Business API", alias="BUSINESS_APP_NAME")
    environment: Literal["development", "test", "staging", "production"] = Field(..., alias="BUSINESS_ENVIRONMENT")
    database_url: str = Field(..., alias="BUSINESS_DATABASE_URL")
    redis_url: str = Field(..., alias="BUSINESS_REDIS_URL")
    jwt_issuer: str = Field(default="liuhetong", alias="BUSINESS_JWT_ISSUER")

def create_app(settings: Settings, session_factory: SessionFactory | None = None) -> FastAPI: ...
```

- [ ] **Step 1: Write failing tests for app metadata, liveness, and missing production secrets**

```python
from fastapi.testclient import TestClient
import pytest
from pydantic import ValidationError

from app.core.config import Settings
from app.main import create_app


def test_live_health_returns_product_identity() -> None:
    settings = Settings(
        BUSINESS_ENVIRONMENT="test",
        BUSINESS_DATABASE_URL="postgresql+psycopg://test:test@localhost/test",
        BUSINESS_REDIS_URL="redis://localhost:6379/1",
    )
    response = TestClient(create_app(settings)).get("/api/v1/health/live")
    assert response.status_code == 200
    assert response.json() == {"ok": True, "service": "六合通 Business API"}


def test_production_requires_explicit_secret_configuration() -> None:
    with pytest.raises(ValidationError):
        Settings(
            BUSINESS_ENVIRONMENT="production",
            BUSINESS_DATABASE_URL="postgresql+psycopg://test:test@localhost/test",
            BUSINESS_REDIS_URL="redis://localhost:6379/1",
        )
```

- [ ] **Step 2: Run tests and verify they fail**

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
py -3.12 -m pytest tests/business_api/test_health.py -q
```

Expected: import failure because `app.core.config` and `app.main` do not exist.

- [ ] **Step 3: Implement settings and factory without import-time global app state**

Use `SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")`. Require `BUSINESS_JWT_SECRET` and `BUSINESS_TOTP_ISSUER` in production through a model validator. The app factory must register only health routes in this task and accept an optional database session factory for readiness tests.

- [ ] **Step 4: Run health tests**

Expected: both tests pass and the app can be imported without a database connection.

- [ ] **Step 5: Commit**

```powershell
git add services/business-api/app tests/business_api/test_health.py
git commit -m "feat: add business api configuration and health"
```

### Task 3: SQLAlchemy Engine, Session Boundary, and Alembic

**Files:**
- Create: `services/business-api/app/core/database.py`
- Create: `services/business-api/alembic.ini`
- Create: `services/business-api/migrations/env.py`
- Create: `services/business-api/migrations/script.py.mako`
- Create: `services/business-api/migrations/versions/0001_business_schema.py`
- Create: `tests/business_api/test_database.py`

**Interfaces:**

```python
def create_engine(settings: Settings) -> Engine: ...
def create_session_factory(engine: Engine) -> sessionmaker[Session]: ...
def check_database(session_factory: sessionmaker[Session]) -> None: ...
```

- [ ] **Step 1: Write a failing PostgreSQL integration test**

The test must use `BUSINESS_DATABASE_URL` from the test environment, skip only when the explicit `RUN_POSTGRES_TESTS` flag is not `1`, create a session, run `SELECT 1`, and assert the connection succeeds. Do not replace this test with a mock.

- [ ] **Step 2: Run the test and record the expected environment skip**

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
py -3.12 -m pytest tests/business_api/test_database.py -q
```

Expected: an explicit `1 skipped` when PostgreSQL is unavailable, not an unhandled connection failure.

- [ ] **Step 3: Implement engine/session helpers and Alembic environment**

Configure pool pre-ping, bounded pool size, and `pool_recycle`. Alembic must import metadata without starting the FastAPI app. The initial migration creates only infrastructure tables: `schema_migrations` is managed by Alembic, and `outbox_events`, `idempotency_records`, and `audit_events` are added in later tasks through the same migration chain.

- [ ] **Step 4: Run static and available integration tests**

Expected: AST parse passes; PostgreSQL test remains an explicit skip until the service is started.

- [ ] **Step 5: Commit**

```powershell
git add services/business-api/app/core/database.py services/business-api/alembic.ini services/business-api/migrations tests/business_api/test_database.py
git commit -m "feat: add business database boundary"
```

### Task 4: Stable Errors and Request Correlation

**Files:**
- Create: `services/business-api/app/core/errors.py`
- Create: `services/business-api/app/core/request_context.py`
- Create: `services/business-api/app/api/error_handlers.py`
- Create: `tests/business_api/test_errors.py`
- Modify: `services/business-api/app/main.py`

**Interfaces:**

```python
class FieldError(BaseModel):
    field: str
    code: str

class AppError(Exception):
    code: str
    status_code: int
    message: str
    field_errors: tuple[FieldError, ...]

def error_response(error: AppError, trace_id: str) -> JSONResponse: ...
```

- [ ] **Step 1: Write failing tests** for `AppError` serialization, unknown exceptions mapping to `INTERNAL_ERROR`, and request `trace_id` propagation in the response header and JSON.
- [ ] **Step 2: Run tests and verify missing module failure.**
- [ ] **Step 3: Implement middleware and exception handlers.** Never return stack traces or secrets to clients; log only a trace ID and structured error metadata.
- [ ] **Step 4: Run tests and verify stable JSON exactly matches `{code,message,trace_id,field_errors}`.**
- [ ] **Step 5: Commit**

```powershell
git add services/business-api/app/core services/business-api/app/api tests/business_api/test_errors.py
git commit -m "feat: add stable business api errors"
```

### Task 5: Idempotency Primitive

**Files:**
- Create: `services/business-api/app/core/idempotency.py`
- Create: `services/business-api/migrations/versions/0002_idempotency.py`
- Create: `tests/business_api/test_idempotency.py`

**Interfaces:**

```python
class IdempotencyConflict(AppError): ...
class IdempotencyService:
    def begin(self, scope: str, key: str, request_hash: str) -> IdempotencyDecision: ...
    def complete(self, record_id: UUID, response_status: int, response_body: dict[str, Any]) -> None: ...
```

- [ ] **Step 1: Write failing tests** for first-use reservation, same-key/same-hash replay returning the original response, same-key/different-hash conflict, and expired-record cleanup.
- [ ] **Step 2: Run tests and verify the service/table are absent.**
- [ ] **Step 3: Implement a unique `(scope,key)` record with SHA-256 request hash, response JSON, status, timestamps, and an atomic reservation transaction.**
- [ ] **Step 4: Run the SQLite unit tests and real PostgreSQL transaction tests when `RUN_POSTGRES_TESTS=1`.**
- [ ] **Step 5: Commit**

```powershell
git add services/business-api/app/core/idempotency.py services/business-api/migrations/versions/0002_idempotency.py tests/business_api/test_idempotency.py
git commit -m "feat: add idempotent request primitive"
```

### Task 6: Transactional Outbox

**Files:**
- Create: `services/business-api/app/core/outbox.py`
- Create: `services/business-api/migrations/versions/0003_outbox.py`
- Create: `tests/business_api/test_outbox.py`

**Interfaces:**

```python
class OutboxPublisher:
    def enqueue(self, session: Session, topic: str, aggregate_id: UUID, payload: dict[str, Any]) -> OutboxEvent: ...

class OutboxConsumer:
    def claim_batch(self, session: Session, limit: int) -> list[OutboxEvent]: ...
    def mark_succeeded(self, session: Session, event_id: UUID) -> None: ...
    def mark_failed(self, session: Session, event_id: UUID, error_code: str) -> None: ...
```

- [ ] **Step 1: Write failing tests** for enqueue-in-same-transaction, rollback removing the event, atomic claim, retry count, and consumer idempotence.
- [ ] **Step 2: Run tests and verify missing table/service failure.**
- [ ] **Step 3: Implement append-only event rows with `available_at`, `attempt_count`, `locked_until`, and `processed_at`.** Claim using row locks/skip-locked on PostgreSQL.
- [ ] **Step 4: Run unit and PostgreSQL integration tests.**
- [ ] **Step 5: Commit**

```powershell
git add services/business-api/app/core/outbox.py services/business-api/migrations/versions/0003_outbox.py tests/business_api/test_outbox.py
git commit -m "feat: add transactional outbox"
```

### Task 7: Worker Skeleton and Compose Integration

**Files:**
- Create: `services/business-worker/app/main.py`
- Create: `services/business-worker/app/worker.py`
- Create: `services/business-worker/requirements.txt`
- Modify: `docker-compose.yml`
- Create: `tests/business_worker/test_worker.py`

**Interfaces:**

```python
class Worker:
    def run_once(self, limit: int = 50) -> int: ...
```

- [ ] **Step 1: Write a failing test** that a worker claims one event, invokes a registered topic handler, and marks success; handler failure increments attempts without deleting the event.
- [ ] **Step 2: Run test and verify missing worker module failure.**
- [ ] **Step 3: Implement a bounded polling worker with graceful shutdown, topic handler registry, and no unbounded retry loop.**
- [ ] **Step 4: Add a `business-api` and `business-worker` Compose service using the pinned Python image and separate health checks.**
- [ ] **Step 5: Run worker tests and `docker compose --env-file .env.example config --quiet`.**
- [ ] **Step 6: Commit**

```powershell
git add services/business-worker docker-compose.yml tests/business_worker
git commit -m "feat: add business worker skeleton"
```

### Task 8: OpenAPI Contract and Phase 1 Verification

**Files:**
- Create: `packages/api-contracts/openapi/liuhetong-v1.yaml`
- Create: `scripts/export_openapi.py`
- Create: `tests/business_api/test_openapi_contract.py`
- Modify: `scripts/verify.ps1`
- Create: `docs/verification/phase-1/`

- [ ] **Step 1: Write failing contract tests** for product title `六合通 Business API`, health routes, stable error schema, and no undocumented financial route in this phase.
- [ ] **Step 2: Run tests and verify the contract file/exporter are absent.**
- [ ] **Step 3: Export the app's OpenAPI to the versioned YAML path and fail if the generated document differs from the committed contract.**
- [ ] **Step 4: Extend `scripts/verify.ps1` to run Phase 1 tests, AST parse, migration checks, and OpenAPI drift checks.**
- [ ] **Step 5: Run the full Phase 1 verification from a clean PowerShell 7 process.**
- [ ] **Step 6: Write `docs/verification/phase-1/summary.md` with red/green evidence and known Docker/PostgreSQL availability.**
- [ ] **Step 7: Commit**

```powershell
git add packages/api-contracts scripts tests docs/verification/phase-1
git commit -m "feat: establish business api contract"
```

## Phase 1 Completion Gate

Phase 1 is complete only when the business app imports without side effects, live health works, PostgreSQL migrations are reproducible, errors are stable, idempotency and Outbox are transactional, the Worker handles retries, OpenAPI has no drift, and all focused/static tests pass. No balance, customer support, red-packet, wallet, or custody behavior may be exposed before its dedicated phase.
