# ChatFlow Unified Performance Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans; each executable change starts with a failing test and records red/green evidence. Specification review precedes quality/security review.

**Goal:** Reuse current bounded diagnostics to correlate a user operation across UI, local data, network, Matrix, media, call, and server stages without collecting identity or content.

**Architecture:** A typed `PerformanceTrace` owns one random operation ID and monotonic stage marks. It stores only bounded local samples in `PerformanceMetrics` and sends sampled, closed records through `ChatDiagnostics`' existing background uploader. Existing frame timing, Matrix sync phases, WebRTC getStats, media scheduler, and FastAPI middleware remain the measurement sources.

**Tech Stack:** Dart/Flutter, existing Matrix fork and `http` client, FastAPI/Pydantic/SQLAlchemy, pytest.

**Baseline:** isolated worktree from `2442f0ab`; main checkout has unrelated uncommitted changes. No production deployment, key/E2EE/ledger/Outbox change, or real user diagnostic request. The user-supplied 2026-09-25 specification is the approved design. Audit: `docs/performance/chatflow-performance-diagnostics.md`.

## File ownership and sequence

- Root: `apps/mobile_flutter/lib/core/performance_*`, `chat_diagnostics*`, `network_state_manager.dart`, matching core/performance tests, plan/task/performance docs, final integration and verification.
- Matrix agent: `features/matrix/matrix_sync_phase_metrics.dart`, `matrix_sync_watchdog.dart`, `call_quality_monitor.dart`, then separately assigned Matrix media/send/room files and matching tests.
- UI/API agent: `core/business_api_client.dart` plus a focused HTTP timing helper, then separately assigned page entrypoints and tests. Root will not edit these files concurrently.
- Server agent: `services/business-api/app/core/tracing.py`, `database.py`, `modules/media/metrics.py`, then `api/client_diagnostics.py`, focused tests, generated OpenAPI and receiver runbook after wire contract is fixed.

## Tasks

### 1. Typed trace and bounded storage

- [x] Write failing Dart tests for one operation ID through all marks, exact monotonic intervals, idempotent finish, abandoned trace release, 100 concurrent operations, bounded samples, privacy rejection and lifecycle isolation. Run focused tests and record expected failures.
- [x] Add closed operation/stage/result/source/network enums and centralized thresholds. Make `mark`/`finish` synchronous, O(1), free of I/O/JSON; never accept raw IDs, text, URI, path, SQL or arbitrary metadata.
- [x] Extend `PerformanceMetrics` snapshot to hold bounded operation/stage percentiles and recent safe records; reuse its frame counters. Extend `ChatDiagnostics` batch queue and old-server 422 fallback, preserving its 60-second cadence, 20-item batch, 100-item cap, abort and backoff. Normal sampling defaults to 5%; slow/error records are retained.
- [x] Add pure classifier tests and rules for UI, storage, transport, Matrix wait/processing, API, media queue/network/decode, WebRTC/TURN, mixed and unknown. Infer only from measured stages and typed states.

### 2. Conversation open and lifecycle

- [x] Write failing widget/unit tests for local-room and pending-conversation opens, ensuring T0–T7 share one ID, route first frame differs from local content and remote sync, and navigation coalescing remains correct.
- [x] Thread the trace through existing `RoomNavigationCoordinator`/`RoomOpenRequest` public flow; mark identity/local lookup, route push, first frame, attach, local timeline, sync readiness without awaiting `Navigator.push` completion. Use source enum and no raw room/user ID.
- [x] Add resume trace at lifecycle transitions and correlate existing Watchdog connection/sync milestones. Tests cover foreground/background/resume and no cross-session carry-over.

### 3. Send, Matrix and media

- [x] Write send/outbox tests proving composer→persist→admission→Matrix send→ack→visible, final state and retry count retain one anonymous ID without changing admission or transaction identity.
- [x] Extend existing sync phase metrics and Watchdog with true cycle total, errors/reconnect/soft kick/hard restart and last healthy age; keep response wait distinct from processing.
- [x] Add media scheduler queue timing and bounded concurrency snapshot; then time cache/download/decrypt/decode only at actual boundaries. Video stages use actual preparation/transcode/poster/upload/event callbacks; unsupported splits remain null.
- [x] Bound existing CallQualityMonitor samples, preserve getStats parser, and correlate CallDiagnostics setup and typed TURN/direct quality summary. Assert no candidate/IP/SDP exposure.

### 4. API, pages and service

- [x] Time Business API at a shared HTTP seam with category/method/status/retry/network evidence; do not include URL/query/token. Classify DNS/connection/read/TLS/offline/HTTP/business errors only where type/status proves it.
- [x] Add route first frame vs content ready to chat list, room, contacts, moments, wallet, profile, search and recent pictures. Preserve local-first rendering; aggregate feed images and bucket search results/rows.
- [x] Extend FastAPI trace middleware with route-template latency/status; add DB actual query latency/pool snapshot and media percentile snapshots. Do not record path params, SQL or bind params. Expose unavailable connection wait as unsupported.
- [x] Extend existing authenticated diagnostics receiver with closed performance operation schema, 16 KiB bound, generated OpenAPI, privacy/rejection tests and older-client compatibility.

### 5. Documentation, review and gates

- [x] Update `docs/performance/chatflow-performance-diagnostics.md` with final data flow, supported operations, thresholds, privacy, six fault patterns and unsupported fields. Update task record and verification evidence under `docs/verification/`.
- [x] Run focused red/green suites, Flutter `analyze lib test`, `test test/features/matrix`, full `flutter test`, server focused tests and `pwsh -NoProfile -File scripts/verify.ps1` after preflight. Record exact exit codes, source/lock hashes, versions and failures; reuse unchanged gates per mobile workflow. `verify.ps1` exited 1 at missing `.env` after three passed steps; all executable downstream steps that do not need `.env` were run independently and are itemized in the verification report.
- [x] Perform specification compliance review, then quality/security review; resolve findings. Do not claim phone or production behavior without device/deployment evidence.
