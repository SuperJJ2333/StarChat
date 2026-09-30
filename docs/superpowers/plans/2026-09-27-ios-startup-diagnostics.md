# iOS Startup Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Tasks below have exclusive file owners; do not edit another owner's files.

**Goal:** Report terminal iOS local session startup failures without reading the failing secure session, retaining only closed metadata.

**Architecture:** Typed safe failure metadata passes through existing exceptions and terminal boundaries without changing recovery decisions. An independent bounded recorder/spool/transport reports to a closed anonymous API with atomic Redis admission and capacity-bounded deduplication. Existing authenticated diagnostics and refresh-watch retain behavior.

**Tech Stack:** Flutter/Dart, dart:io/path_provider, FastAPI/Pydantic, Redis Lua, pytest/Flutter tests.

Approved [design](../specs/2026-09-27-ios-startup-diagnostics-design.md) and [ADR](../../adr/2026-09-27-preauth-startup-diagnostics.md).

## Task 1 — Safe metadata and terminal startup wiring (root)

Files: new `apps/mobile_flutter/lib/core/startup_failure_metadata.dart`; modify `installation_reconciler.dart`, `installation_startup_gate.dart`, `session_bootstrap_controller.dart`, `features/matrix/local_identity_preflight.dart`, `features/matrix/matrix_client_factory.dart`, `features/auth/login_controller.dart`, `main.dart`. Add focused tests in `test/core/startup_failure_metadata_test.dart`, `test/core/installation_startup_diagnostics_test.dart`, and existing relevant preflight/login/bootstrap tests.

- [x] Write tests for direct PlatformException -25308/-34018, wrapped preflight errors, L04/L07 safe metadata, unknown status projection, callback throwing isolation and unchanged preflight/retry behavior.
- [x] Run `flutter test --no-pub test/core/startup_failure_metadata_test.dart` before code and retain failing exit.
- [x] Implement immutable safe types and a provider interface. `safeStartupFailure(error, boundary: boundary)` returns only enums; native status accepts exact documented PlatformException shapes. Preflight/LoginStageException implement the provider and preserve safe metadata through wrappers. `notifyStartupFailure(observer, metadata)` catches callback faults.
- [x] Add optional callbacks in reconciler/Gate/bootstrap and invoke only at terminal failure boundaries; keep partial breadcrumbs in exceptions rather than a mutable global stage. Root wires recorder before first await, separate stage closures at salt/installation/Matrix work, and lifecycle flush. No observer changes existing results or stores.
- [x] Run focused startup/preflight/login/bootstrap tests and analyze, retain source SHA/timings and inspect diff for unchanged recovery conditions.

## Task 2 — Independent recorder, spool and HTTP uploader (mobile agent)

Files owned only: new `apps/mobile_flutter/lib/core/startup_diagnostics.dart`, `startup_diagnostics_spool.dart`, `startup_diagnostics_transport.dart`; tests with matching new names under `test/core/`. No existing files except owner-approved integration.

- [x] Write and run failing tests: no-session HTTP upload, forbidden field absence, startup not blocked by never-ending spool/transport, bounded bytes/count/age, immutable first-attempt body, concurrency, retry budget, corrupt queue, lifecycle flush and cancellation.
- [x] Implement `StartupDiagnostics` with `record(StartupFailureStage stage, StartupFailureMetadata failure)`, `initialize()` and `flush()`; synchronous memory recording, all I/O no-throw/bounded, injected clock/spool/upload for tests. Platform iOS only by default. Frozen metadata exactly matches design fields.
- [x] Persist only decoded/validated reports to one fixed app-support queue, cap20/32KiB/24h, ignore symlinks/nonfiles/oversize/corrupt, serialize operations and memory fallback. Requests have5s absolute deadline, no redirects/cookies/token reads, response bounded and only validated202/event UUID removes event. One in-flight attempt, retries30s/2m/10m then wait next lifecycle; no recursive diagnostics.
- [x] Run focused tests and Dart format/analyze of owned files, send public constructor/wire API to root before integration. Do not modify session/Matrix behavior.

## Task 3 — API admission/dedup receiver (backend agent)

Files: new `services/business-api/app/api/startup_diagnostics.py`, dedicated `app/core/startup_diagnostics_admission.py`; modify `app/main.py`, `app/core/tracing.py`, `packages/api-contracts/openapi/liuhetong-v1.yaml`; new `tests/business_api/test_startup_diagnostics.py` and `test_startup_diagnostics_admission.py`. Preserve inherited e880/6033 changes in modified files.

- [x] Write and run failing tests for closed report acceptance without bearer, private field rejection/no echo/no logs, bytes/chunked limits, time/version/enum constraints, strict booleans/numbers, 401 on old receiver, duplicate/concurrent/busy/expired/failure behavior and atomic gates.
- [x] Implement strict report model with literal/regex bounded values from design, manual bounded body read, generic errors and safe log only. Injectable admission protocol lets tests use real behavior in a bounded memory double.
- [x] Implement production Redis Lua admission with global-first atomic counters+TTL, source10/min/global120/min, fixed dedup capacity10000/24h and pending lease; complete only after print succeeds, release best effort after failure, Redis failure503. No direct session/identity/ledger tables.
- [x] Run targeted pytest plus old diagnostics/network/OpenAPI tests, export OpenAPI and report exact counts, SHA and exits. No production deployment or worker/database change.

## Task 4 — Evidence, read-only collector and reviews (root after tasks1–3)

Files: new `scripts/collect_startup_diagnostics.py`, `tests/infra/test_startup_diagnostics_collection.py`, `docs/runbooks/ios-startup-diagnostics.md`, verification/task record/current-state.

- [x] Write failing collector tests using mixed log envelopes, malformed/private/oversize lines, untrusted events and version/category grouping; implement whitelist parsing and bounded stream, output counts/safe sample UUID only, no original lines.
- [x] Perform spec/domain review then quality/security review on final scoped source and ADR; address all concrete findings with red/green evidence.
- [x] Preflight `scripts/verify.ps1`; execute required gate using change-impact/evidence rules. Run full Flutter gate only after source settles. Keep genuine exits/skips/failures; no optional repeated build.
- [x] Freeze manifest/locks/tools/source SHA; write rollout candidate/rollback with actual currentAPI baseline, then request separate production publish approval if a candidate is fully ready. User-approved code implementation does not grant service release.
- [x] Backfill only scoped owned files with drift/hash guard to shared D workspace; preserve concurrent tasks/current-state. State iOS new signed build/real device evidence gap accurately; do not claim old0.4.7 already sends new telemetry.

## Final execution closure

Final implementation/reviews and source gates are recorded in [verification](../../verification/2026-09-27-ios-startup-diagnostics.md). The initial aggregate script genuinely exited1 on a globally patched Redis test fixture; its module-scoped test-only correction and the remaining script stages close the gate without claiming the original run exited0. The final Lua/collector deltas have focused final-source evidence. No session_failure/exporter/native file or dependency changed in this task. Production release and signed iOS distribution remain separate subsequent steps; the implementation checklist does not claim affected-device delivery.
