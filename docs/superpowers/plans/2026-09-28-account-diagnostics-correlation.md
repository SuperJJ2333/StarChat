# Account Diagnostics Correlation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let authorized operators find bounded network and performance diagnostics for a test account by its exact current 畅聊号, and correlate client UI stages with server time without exposing account identifiers or chat content in routine logs and exports.

**Architecture:** The authenticated receiver derives domain-separated HMAC references from the already validated user and device claims; an operator-only local resolver maps an exact current handle to current and previous-key references. Clients emit closed, bounded stage metrics and UTC windows only when an in-memory server Date anchor is fresh. Existing anonymous startup diagnostics remain anonymous, and generic triage/export omits identity references.

**Tech Stack:** FastAPI, Pydantic v2, SQLAlchemy, Python 3.12 pytest, Flutter/Dart tests, PowerShell 7, existing Docker JSON-file logs.

---

## Ownership and execution gate

This plan owns only the diagnostic receiver, identity resolver, time-anchor/wire protocol, privacy-aware triage/export, tests, OpenAPI, and diagnostic runbooks. The companion chat-search/room plan owns the producers of search, keyboard, room, and Matrix sync marks; coordinate the closed operation names before either side edits `performance_trace_model.dart`. Do not edit the same file concurrently.

Before the first RED test, read `docs/runbooks/mobile-delivery-workflow.md`, `docs/workflow/current-state.md`, the approved `docs/superpowers/specs/2026-09-28-chat-search-jank-diagnostics-design.md`, and the linked task record. This worktree currently starts at `e31de0a27b098e49159d8ce713d99693e7773e85`; it is missing some files shipped in Android 2190, including `apps/mobile_flutter/lib/core/network_request_diagnostics.dart` and three diagnostic collection scripts. Restore the complete 2190 frozen source and dependency set in this isolated worktree, compare every relevant file hash against the task record's 2190 manifest, and stop if any source identity remains unexplained. The dirty main checkout is a reference, not proof of production. `.codegraph/` is absent in this worktree; if an index appears, query it before text search.

At the beginning of every PowerShell session run:

```powershell
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
```

Baseline check after restoration:

```powershell
git rev-parse HEAD
git status --short
git hash-object apps/mobile_flutter/lib/core/chat_diagnostics.dart apps/mobile_flutter/lib/core/network_request_diagnostics.dart services/business-api/app/api/client_diagnostics.py scripts/client_diagnostics_triage.py scripts/collect_network_diagnostics.py scripts/collect_network_request_diagnostics.py
```

Record these hashes and the matching 2190 manifest entries in `docs/workflow/tasks/2026-09-28-chat-search-jank-diagnostics.md`; all subsequent diffs are relative to the restored 2190 baseline. Do not run a source build from this old remote HEAD and call it a 2190 comparison.

## File map and protocol choices

| File | Responsibility |
| --- | --- |
| `services/business-api/app/core/diagnostic_identity.py` | Pure domain-separated HMAC for authenticated subject and device IDs; current/previous-key reference resolution. |
| `services/business-api/app/core/config.py`, `.env.example` | Dedicated private diagnostic HMAC secret, previous secret, production validation. |
| `services/business-api/app/api/client_diagnostics.py` | Validate the existing access token/session; derive refs at ingest; closed time/stage schema; keep old batches valid. |
| `scripts/diagnostic_account_query.py` | Private exact-handle resolver and bounded local log query. No HTTP route. |
| `scripts/client_diagnostics_triage.py`, `scripts/collect_network_diagnostics.py`, `scripts/collect_network_request_diagnostics.py` | Accept valid new log envelope, strip refs from generic output. |
| `apps/mobile_flutter/lib/core/diagnostic_time_anchor.dart` | Five-minute in-memory server Date calibration with RTT/uncertainty. |
| `apps/mobile_flutter/lib/core/business_api_performance_client.dart`, `apps/mobile_flutter/lib/core/business_api_client.dart` | Feed Date headers from existing authenticated requests, without extra UI-time network calls. |
| `apps/mobile_flutter/lib/core/performance_trace_model.dart`, `apps/mobile_flutter/lib/core/performance_trace.dart` | Closed operation/stage counters and optional calibrated UTC start/end. |
| `apps/mobile_flutter/lib/core/chat_diagnostics.dart`, `apps/mobile_flutter/lib/core/chat_diagnostics_spool_store.dart` | Preserve new records across the bounded spool and strip extensions for a 422 older API fallback. |
| `packages/api-contracts/openapi/liuhetong-v1.yaml` | Generated authenticated diagnostic request contract. |
| `docs/runbooks/client-diagnostics.md`, `docs/runbooks/network-request-diagnostics.md`, `docs/performance/chatflow-performance-diagnostics.md` | Restricted lookup, key rotation, coverage, sampling, and time-correlation limitations. |

Wire names for this plan: log-only `subject_ref` and `device_ref` are 64 lowercase hex characters. Clients never send them. Optional operation fields are `started_at_utc`, `ended_at_utc`, `clock_uncertainty_ms`, `time_anchor_age_ms`; they appear together or not at all. Closed extra operation kinds are `history_search`, `keyboard_transition`, and `room_local_frame`; the existing `matrix_sync` operation carries sync volume. The companion plans own event producers. The receiver accepts old clients with none of these fields. UTC fields are omitted if the Date anchor is stale or too uncertain; no local wall-clock guess is logged as calibrated UTC.

### Task 1: Authenticated HMAC identity and dedicated secret

**Files:**
- Create: `services/business-api/app/core/diagnostic_identity.py`
- Modify: `services/business-api/app/core/config.py`
- Modify: `.env.example`
- Modify: `services/business-api/app/api/client_diagnostics.py`
- Create: `tests/business_api/test_diagnostic_identity.py`
- Modify: `tests/business_api/test_client_diagnostics.py`

- [ ] **Step 1: Write RED tests.** Assert that the same immutable `User.id` produces the same subject reference after a username change, distinct IDs and HMAC domains produce different references, previous secret is query-only, raw `username`, `user_id`, `device_id`, `subject_ref`, and `device_ref` in client JSON each get 422, and a valid authenticated batch logs only server-derived refs. Existing sub-only JWT test fixtures stay valid in `environment=test`; a real session-claim token yields both refs. Anonymous `/api/v1/startup-diagnostics` still has no refs. Use a fixed 32-byte test secret and the existing `TestClient` fixtures. The core assertion shape is:

```python
from app.core.diagnostic_identity import diagnostic_ref

def test_subject_and_device_domains_do_not_collide():
    key = b'0123456789abcdef0123456789abcdef'
    subject = diagnostic_ref(key, 'subject', 'stable-user-id')
    device = diagnostic_ref(key, 'device', 'stable-user-id')
    assert len(subject) == 64 and subject != device
    assert subject == diagnostic_ref(key, 'subject', 'stable-user-id')
```

- [ ] **Step 2: Confirm RED.** Run `python -m pytest tests/business_api/test_diagnostic_identity.py tests/business_api/test_client_diagnostics.py -q`; new tests fail because `diagnostic_ref` and receiver refs do not exist, while unchanged legacy tests remain green.

- [ ] **Step 3: Add only the identity primitive and config.** Implement `diagnostic_ref(secret: bytes, domain: Literal['subject','device'], value: str) -> str` with `hmac.new(secret, b'chatflow/diagnostics/' + domain.encode('ascii') + b'/v1\0' + value.encode('utf-8'), hashlib.sha256).hexdigest()`. Reject an empty value/key. Add `diagnostic_identity_secret: SecretStr | None` and `diagnostic_identity_previous_secret: SecretStr | None` to `Settings`; production validation requires a non-placeholder current secret of at least 32 UTF-8 bytes, distinct from the previous secret and JWT secret. In nonproduction, absent current secret generates one process-local random key at app construction, never a checked-in shared constant. Add blank `BUSINESS_DIAGNOSTIC_IDENTITY_SECRET=` and `BUSINESS_DIAGNOSTIC_IDENTITY_PREVIOUS_SECRET=` example lines.

```python
def diagnostic_ref(secret: bytes, domain: Literal['subject', 'device'], value: str) -> str:
    if len(secret) < 32 or not value:
        raise ValueError('Invalid diagnostic identity input')
    prefix = b'chatflow/diagnostics/' + domain.encode('ascii') + b'/v1\0'
    return hmac.new(secret, prefix + value.encode('utf-8'), hashlib.sha256).hexdigest()
```

- [ ] **Step 4: Derive refs after existing token validation.** In `create_client_diagnostics_router`, have `actor` return the decoded validated claims instead of only `sub`. Keep account/IP rate limits as-is; after `DiagnosticBatch.model_validate_json`, append `subject_ref = diagnostic_ref(key, 'subject', claims['sub'])`. Append `device_ref` only when a validated `device_id` exists; production `TokenService.decode_access_token` already requires and validates it against `User`, `Device`, and `RefreshTokenFamily`. Do not read username during ingest and do not alter the anonymous receiver. Keep `DiagnosticBatch(extra='forbid')` so client-supplied refs/handle fail before logging. The log line is assembled from the validated batch, then server refs, and written with the existing 16 KiB body and rate limits.

```python
claims = tokens.decode_access_token(authorization[7:])
safe = {'event': 'client_diagnostics', **batch.model_dump(mode='json', exclude_unset=True)}
safe['subject_ref'] = diagnostic_ref(key, 'subject', str(claims['sub']))
if claims.get('device_id'):
    safe['device_ref'] = diagnostic_ref(key, 'device', str(claims['device_id']))
```

- [ ] **Step 5: Confirm GREEN and commit.** Run `python -m pytest tests/business_api/test_diagnostic_identity.py tests/business_api/test_client_diagnostics.py -q` and expect all tests to pass. Commit the six owned paths as `feat(diagnostics): correlate authenticated records with private references`; never print the key in test output.

### Task 2: Closed UTC and stage contract, with old-client compatibility

**Files:**
- Modify: `services/business-api/app/api/client_diagnostics.py`
- Modify: `tests/business_api/test_client_diagnostics.py`
- Modify: `packages/api-contracts/openapi/liuhetong-v1.yaml` (generated)
- Test: `tests/business_api/test_openapi_contract.py`

- [ ] **Step 1: Add RED tests for the exact wire contract.** Keep all existing payloads valid. A new final operation with `started_at_utc`, `ended_at_utc`, `clock_uncertainty_ms`, and `time_anchor_age_ms` is accepted only when all four are supplied, both times are UTC, end is no earlier than start, anchor age is at most 300000 ms, uncertainty is at most 2000 ms, and wall duration agrees with `total_ms` within uncertainty plus Date-header granularity (1000 ms). Reject raw query text, room ID, username, URL, arbitrary stage/reason labels, negative/oversized counts, and UTC fields on incomplete observations. Include operation examples for `history_search`, both `keyboard_transition` directions, both `room_local_frame` phases, and existing `matrix_sync` with `timeline_event_count`. Assert generated OpenAPI includes the new closed fields but no `username`, `subject_ref`, or `device_ref` request fields.

```python
def test_partial_utc_window_is_rejected(authenticated_client, valid_batch):
    record = valid_batch['operations'][0]
    record['started_at_utc'] = '2026-09-28T12:00:00Z'
    assert authenticated_client.post('/api/v1/client-diagnostics', json=valid_batch).status_code == 422
```

- [ ] **Step 2: Confirm RED.** Run `python -m pytest tests/business_api/test_client_diagnostics.py tests/business_api/test_openapi_contract.py -q`; the positive new-wire case fails while legacy tests stay green.

- [ ] **Step 3: Extend only static receiver literals and bounded metadata.** Add `history_search`, `keyboard_transition`, and `room_local_frame` to `OperationWire`; keep the existing `matrix_sync`. Add stage literals `search_scan_started`, `search_first_hit`, `search_coverage_complete`, `keyboard_requested`, `keyboard_stable_frame`, `room_local_first_frame`, `route_exit_requested`, `route_exit_frame`, `fragment_write_started`, `fragment_write_done`; enums `restart_reason: Literal['query_changed','manual_refresh','safety_invalidation'] | None`, `cancel_reason: Literal['new_query','route_closed','account_changed','visibility_revoked'] | None`, `keyboard_direction: Literal['show','hide'] | None`, and `room_route_phase: Literal['enter','leave'] | None`. Require `keyboard_direction` on `keyboard_transition` and `room_route_phase` on `room_local_frame`; forbid those fields on other operations. Add integer fields `scan_page_count` (0..100000), `scan_row_count` (0..10000000), `timeline_event_count` (0..100000), `first_hit_ms` and `full_coverage_ms` (0..3600000). `timeline_event_count` means raw joined/left timeline envelopes in one sync cycle, not confirmed decrypted user messages; allow it only on `matrix_sync`. Put these on `_PerformanceMetadata` only when meaningful for the operation and validate combinations with a model validator. Do not introduce a free-text metadata map. On `PerformanceOperation` only, add the four UTC fields and the all-or-none/ordered/duration checks; accept old final and observation rows unchanged. Serialize UTC times as RFC3339 `Z` or `+00:00` and reject non-UTC offsets.

```python
window_fields = ('started_at_utc', 'ended_at_utc', 'clock_uncertainty_ms', 'time_anchor_age_ms')
present = [name in self.model_fields_set for name in window_fields]
if any(present) and not all(present):
    raise ValueError('Incomplete calibrated time window')
if all(present):
    if self.ended_at_utc < self.started_at_utc:
        raise ValueError('Invalid calibrated time window')
    wall_ms = (self.ended_at_utc - self.started_at_utc).total_seconds() * 1000
    if abs(wall_ms - self.total_ms) > self.clock_uncertainty_ms + 1000:
        raise ValueError('Inconsistent calibrated duration')
```

- [ ] **Step 4: Generate and verify against the actual service baseline.** If the shared service source exactly matches the current production image, run `python scripts/export_openapi.py`, `python scripts/export_openapi.py --check`, and the receiver/OpenAPI tests; never manually edit generated YAML. For this implementation, production moved to API image `8015…` with poster routes and 0091 while the shared source still predates it. Use the isolated `candidate-8015-tree`, `make_snapshot_openapi.py --check`, and `check_candidate.py` described in the candidate report; prove 326 paths/351 route pairs and only the diagnostics request-body change. Keep the tracked shared OpenAPI unchanged until a separate production-source baseline sync, since regenerating it now would delete published routes. Run receiver tests with `PYTHONPATH=candidate-8015-tree` and commit only the diagnostic source/test changes.

### Task 3: Five-minute in-memory Date anchor and bounded Flutter wire

**Files:**
- Create: `apps/mobile_flutter/lib/core/diagnostic_time_anchor.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_performance_client.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/lib/core/performance_trace_model.dart`
- Modify: `apps/mobile_flutter/lib/core/performance_trace.dart`
- Modify: `apps/mobile_flutter/lib/core/chat_diagnostics.dart`
- Modify: `apps/mobile_flutter/lib/core/chat_diagnostics_spool_store.dart`
- Create: `apps/mobile_flutter/test/core/diagnostic_time_anchor_test.dart`
- Modify: `apps/mobile_flutter/test/performance/performance_trace_upload_test.dart`
- Modify: `apps/mobile_flutter/test/performance/performance_trace_test.dart`
- Modify: `apps/mobile_flutter/test/core/chat_diagnostics_spool_test.dart`
- Modify: `apps/mobile_flutter/test/core/business_api_diagnostics_test.dart`

- [ ] **Step 1: Write RED anchor tests.** Inject a monotonic millisecond clock. Accept only an authenticated Business API or diagnostic response's parseable RFC1123 `Date`, with measured response-header RTT ≤2000 ms. Estimate server time at the request midpoint and set uncertainty to `1000 + RTT ~/ 2` ms (Date has one-second precision). Do not anchor a failed request, untrusted endpoint, clock reversal, or a response whose Date cannot parse. At age 300000 ms the anchor can be used; at 300001 ms it cannot. An offline-spooled record retains its original calibrated UTC fields, or none; upload time never rewrites event time. A keyboard transition causes no extra HTTP request.

```dart
test('stale calibration never produces UTC', () {
  var nowMs = 1000;
  final anchor = DiagnosticTimeAnchor(monotonicMs: () => nowMs);
  anchor.observe(dateHeader: 'Mon, 28 Sep 2026 12:00:00 GMT',
      sentAtMs: 900, receivedAtMs: 1000);
  nowMs = 1100;
  expect(anchor.window(1000, 1100), isNotNull);
  nowMs = 301001;
  expect(anchor.window(301001, 301101), isNull);
});
```

- [ ] **Step 2: Confirm RED.** From `apps/mobile_flutter`, run `flutter test --no-pub test/core/diagnostic_time_anchor_test.dart test/performance/performance_trace_upload_test.dart test/core/chat_diagnostics_spool_test.dart`; the new class and wire expectations fail.

- [ ] **Step 3: Implement pure calibration.** `DiagnosticTimeAnchor` stores only `(serverDateUtc, midpointMonotonicMs, uncertaintyMs, observedMonotonicMs)` in RAM; it exposes `observe({required String? dateHeader, required int sentAtMs, required int receivedAtMs})` and `window(int startMs, int endMs)`. Discard `RTT > 2000`, invalid Date, future/reversed monotonic points, and age `> 300000`. A returned immutable `DiagnosticUtcWindow` carries RFC3339 UTC start/end, `clockUncertaintyMs`, and `timeAnchorAgeMs`. Reset on authenticated account/session change. Feed it from the HTTP wrapper at the existing send/response-header boundary and the dedicated diagnostic upload response; do not send a calibration request. For `http.StreamedResponse`, read `response.headers['date']`; for `dart:io HttpClientResponse`, read `response.headers.value(HttpHeaders.dateHeader)`.

```dart
final rttMs = receivedAtMs - sentAtMs;
if (rttMs < 0 || rttMs > 2000 || dateHeader == null) return;
final midpointMs = sentAtMs + rttMs ~/ 2;
final uncertaintyMs = 1000 + rttMs ~/ 2;
```

- [ ] **Step 4: Add immutable operation fields, closed counters and stages.** In `PerformanceRecord`, add optional `DiagnosticUtcWindow? utcWindow`, `scanPageCount`, `scanRowCount`, `timelineEventCount`, `firstHitMs`, `fullCoverageMs`, and fixed enums for restart/cancel reason, `keyboardDirection`, and `roomRoutePhase`; validate ranges and operation combinations before serialization. In `PerformanceTraceRecorder`, capture monotonic start/end and call `DiagnosticTimeAnchor.window(startMs, endMs)` at `finish`; preserve UTC/counters in `withFrameAttribution` and spool encode/decode. Emit the exact server snake_case names only when present. Add the three new operation and ten stage wire names from Task 2 to the Dart enum mapping; preserve existing `matrixSync`. Keep payload size ≤15 KiB and queue bounds unchanged.

```dart
if (utcWindow != null) ...{
  'started_at_utc': utcWindow!.startedAtUtc,
  'ended_at_utc': utcWindow!.endedAtUtc,
  'clock_uncertainty_ms': utcWindow!.uncertaintyMs,
  'time_anchor_age_ms': utcWindow!.anchorAgeMs,
},
```

- [ ] **Step 5: Test a 422 older receiver.** Update `_hasOperationExtension` and `_operationWireJson`: a 422 disables the new stage/counter/UTC extension for the process and retries legacy operations on the existing bounded cadence; new-only operation kinds are dropped with diagnostic loss accounting, never relabeled as unrelated operations. Preserve baseline `message_send`, `conversation_open`, `api_request`, and network diagnostic records. Validate that no repeated 422 loop occurs. The exact compatibility assertion is: first upload with new fields gets 422; next upload contains neither UTC keys nor new-only operation kinds but does contain the unchanged legacy operation ID and result.

- [ ] **Step 6: Confirm GREEN and commit.** Run `flutter test --no-pub test/core/diagnostic_time_anchor_test.dart test/performance/performance_trace_upload_test.dart test/performance/performance_trace_test.dart test/core/chat_diagnostics_spool_test.dart test/core/business_api_diagnostics_test.dart`, then `flutter analyze --no-pub` from `apps/mobile_flutter`. Expect all focused tests and analysis to pass. Commit these paths as `feat(diagnostics): calibrate bounded UI operation windows`. Search/keyboard/room/sync call sites are added by the companion plan using this closed contract.

### Task 4: Private exact-handle lookup and identity-free generic tools

**Files:**
- Create: `scripts/diagnostic_account_query.py`
- Modify: `scripts/client_diagnostics_triage.py`
- Modify: `scripts/collect_network_diagnostics.py`
- Modify: `scripts/collect_network_request_diagnostics.py`
- Create: `tests/infra/test_diagnostic_account_query.py`
- Modify: `tests/infra/test_client_diagnostics_triage.py`
- Modify: `tests/infra/test_network_collection.py`
- Modify: `tests/infra/test_network_request_collection.py`

- [ ] **Step 1: Write RED tests with synthetic accounts/logs.** `resolve_refs(session, exact_current_handle, current_key, previous_key)` executes one equality query on `User.username_normalized`, returns current and previous HMACs of immutable `User.id`, and gives one fixed `LookupError('Account not found')` for absent/old/partial handles. Different-case exact current handle resolves; a prefix does not. An account that changed its current handle still matches old diagnostic rows by immutable ID. Reject a third previous key, free-text/filter lists, and `since_hours` outside 1..168. Private log output groups a valid device ref into ephemeral `device_1`/`device_2`, shows bounded operation/network stages and UTC coverage, omits full handle/raw refs, and never claims 7 days when Docker byte rotation preserved less. An upload delayed by offline spool is marked `time_uncertain` unless its record has valid calibrated UTC. Direct request UUID joins take precedence over time overlap; mere overlap is `coincident`, not `causal`.

```python
def test_exact_current_handle_only(session, account, keys):
    refs = resolve_refs(session, account.username_normalized.upper(), *keys)
    assert refs[0] == diagnostic_ref(keys[0], 'subject', account.id)
    with pytest.raises(LookupError, match='^Account not found$'):
        resolve_refs(session, account.username_normalized[:-2], *keys)
```

- [ ] **Step 2: Test generic export privacy before modifying it.** Feed one valid client log line with well-formed server `subject_ref`/`device_ref` through `summarize_logs`, `sanitize_record`, and `sanitize_logs`; expect acceptance but assert neither ref nor handle appears anywhere in returned JSON. Feed malformed refs, uppercase hex, or unrecognized envelope fields; expect rejection and incomplete coverage rather than silent passthrough. Existing older log lines without refs remain accepted. Run `python -m pytest tests/infra/test_diagnostic_account_query.py tests/infra/test_client_diagnostics_triage.py tests/infra/test_network_collection.py tests/infra/test_network_request_collection.py -q`; new tests fail for missing resolver and new envelope keys.

- [ ] **Step 3: Implement the private resolver with read-only DB access.** Use `select(User.id).where(User.username_normalized == handle.casefold())`; never use `LIKE`, suffix tolerance, `UsernameClaim`, phone, email, Matrix ID, or a client-submitted username. Limit the interactive input to the account field's 64-character maximum and read it through `getpass.getpass`, not a command-line argument or environment variable. Build a `ReadonlyRefs` value from the current and optional previous private key. Keep the handle only in process memory and clear the local reference after resolution. Use `app.core.database.create_engine/create_session_factory` with `Settings` in a restricted maintenance process using the same candidate service code/config; require an operator terminal and do not add an API route or web UI. On the server, save `docker logs --timestamps` stdout to a root-only temporary file, mount it read-only into that process, then redirect the process's stdin from the file while retaining its TTY for `getpass`; plain `docker logs` without `--timestamps` is invalid. The CLI also accepts raw Docker JSON-file envelopes from a root-only local file. It accepts `--since-hours 1..168`, never echoes the typed handle, and prints only aggregates, `device_1` labels, fixed stages/error classes, `coverage_first_utc`, `coverage_last_utc`, `coverage_incomplete`, and `time_uncertain_count`. A missing account returns the same terse error regardless of why it did not resolve.

```python
def resolve_refs(session, handle: str, current_key: bytes, previous_key: bytes | None):
    if not 1 <= len(handle) <= 64:
        raise LookupError('Account not found')
    user_id = session.scalar(
        select(User.id).where(User.username_normalized == handle.casefold())
    )
    if user_id is None:
        raise LookupError('Account not found')
    keys = (current_key,) if previous_key is None else (current_key, previous_key)
    return tuple(diagnostic_ref(key, 'subject', str(user_id)) for key in keys)
```

- [ ] **Step 4: Bound and sanitize private log parsing.** Reuse the same 65536-byte line, 100000-line, and 20000-record caps as `client_diagnostics_triage.py`; parse either a strict RFC3339 UTC `docker logs --timestamps` prefix or a Docker JSON-file envelope with a strict UTC `time` field. Include at most `since_hours` worth of records, and print actual coverage start/end rather than a fixed retention claim. Validate refs against `^[0-9a-f]{64}$`, then filter by the current/previous subject refs before loading the strict `DiagnosticBatch` model. Output time-window rows only with both UTC fields and a fresh anchor age; otherwise increment `time_uncertain_count`. First use a direct request UUID; classify mere server interval overlap as `coincident` only within the same validated `device_ref`. Unknown-device records cannot use interval coincidence. No raw UUID, source line, credential, exception string, query text, room ID, or device ref enters stdout/stderr. Docker currently rotates logs by 20 MiB × 10, so a seven-day query is only an upper limit. Freeze this tool, the generic triage/collector scripts, and matching candidate service DTO source in a restricted operations bundle; test the bundle on synthetic `docker logs --timestamps` input before service publication.

- [ ] **Step 5: Update generic parsers.** In `client_diagnostics_triage.py`, add exactly `subject_ref` and `device_ref` to `_BATCH_KEYS`, validate each against the lower-hex regex, remove both before `DiagnosticBatch.model_validate`, and never use them as aggregate grouping keys. In both network collectors, add the two keys to the strict envelope allowlist, validate then discard them before constructing safe output. Keep anonymous startup collector and server request-timeline output unchanged.

```python
identity = {name: raw.pop(name) for name in ('subject_ref', 'device_ref') if name in raw}
if any(not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{64}', value) is None
       for value in identity.values()):
    raise ValueError('Invalid diagnostic reference')
batch = model_type.model_validate({key: value for key, value in raw.items() if key != 'event'})
```

- [ ] **Step 6: Confirm GREEN and commit.** Run `python -m pytest tests/infra/test_diagnostic_account_query.py tests/infra/test_client_diagnostics_triage.py tests/infra/test_network_collection.py tests/infra/test_network_request_collection.py -q`. Require old/new valid logs accepted, malformed logs rejected, no identity in any generic output, and bounded private coverage. Commit the eight owned paths as `feat(diagnostics): add restricted exact-account triage`.

### Task 5: Rollout evidence, documentation, and final verification

**Files:**
- Modify: `docs/runbooks/client-diagnostics.md`
- Modify: `docs/runbooks/network-request-diagnostics.md`
- Modify: `docs/performance/chatflow-performance-diagnostics.md`
- Modify: `docs/workflow/tasks/2026-09-28-chat-search-jank-diagnostics.md`
- Create: `docs/verification/2026-09-28-account-diagnostics-correlation.md`

- [ ] **Step 1: Add runbook rules.** Document: exact current handle to immutable user ID; dedicated HMAC current/previous secret stored only in private production configuration; previous key retained read-only for the surviving log window, then retired; interactive restricted server lookup; no public query/bulk export; generic output excludes refs; Docker 20 MiB × 10 rotation and 168-hour maximum query; direct UUID versus estimated UTC correlation, 5-minute anchor expiry and uncertainty; account/device pseudonyms are still sensitive operational metadata and need the same restricted access as diagnostic logs. Document that changing a handle does not change historical subject ref, that old handle lookup is unavailable without separately authorized account audit, and that anonymous startup diagnostics cannot be attributed to an account.

- [ ] **Step 2: Record staged deployment order.** First stage and verify private triage/collectors capable of old and new envelopes, without exporting raw logs. Provision the new diagnostic HMAC key only in the root-only candidate production configuration; preserve the exact old API image and its existing configuration as the rollback pair, and never echo or store the key in Git. Build and verify the API candidate from the current production image, including final-image refresh protocol, 326-route/poster contract, diagnostic auth, and an isolated production `Settings()` key preflight. Freeze candidate and rollback API/worker image+Compose pairs through the current refresh guard, then request the separate service deployment approval required by `docs/runbooks/app-release-deployment.md` before replacing production. After receiver health/auth/rate-limit/anonymous checks, ship the Android client candidate. A new client against an older server must use the Task 3 one-time 422 fallback. No database migration is needed. iOS distribution is outside this Android-specific diagnostic task.

- [ ] **Step 3: Run final focused and required gates.** From the restored 2190-based worktree, run:

```powershell
$artifact = Join-Path (Get-Location) 'docs/verification/artifacts/2026-09-28/chat-search-jank'
$env:PYTHONPATH = Join-Path $artifact 'candidate-8015-tree'
python -m pytest tests/business_api/test_diagnostic_identity.py tests/business_api/test_client_diagnostics.py tests/business_api/test_diagnostic_time_wire.py tests/business_api/test_network_diagnostics.py tests/business_api/test_network_request_diagnostics.py tests/infra/test_diagnostic_account_query.py tests/infra/test_client_diagnostics_triage.py tests/infra/test_network_collection.py tests/infra/test_network_request_collection.py -q
python (Join-Path $artifact 'make_snapshot_openapi.py') --check
python (Join-Path $artifact 'check_candidate.py')
python (Join-Path $artifact 'check_restricted_ops_bundle.py')
Push-Location apps/mobile_flutter
flutter test --no-pub test/core/diagnostic_time_anchor_test.dart test/performance/performance_trace_upload_test.dart test/performance/performance_trace_test.dart test/core/chat_diagnostics_spool_test.dart test/core/business_api_diagnostics_test.dart
flutter analyze --no-pub
Pop-Location
git diff --check
```

The expected outcome is zero failures, an isolated 8015 candidate contract check, and no whitespace errors. The tracked shared OpenAPI is not an input for this service candidate. Preflight the environment for `pwsh -NoProfile -File scripts/verify.ps1`; run it once if inputs changed and required dependencies are available. Reuse an equivalent completed gate only when its source/dependency/tool hashes match under the mobile delivery runbook. Record any environment block or platform gap explicitly; do not call it a pass.

- [ ] **Step 4: Complete acceptance evidence and reviews.** Record red/green commands, source hashes, payload size and loss behavior, exact-handle/no-enumeration proof, rotation lookup, invalid/expired token denial, device/session binding, generic export redaction, offline delayed upload classification, log coverage, old server compatibility, and version/platform/sample counts. Conduct specification-compliance review before quality/security review. Verify on an Android simulator using synthetic account/operation data, then request Redmi K80 evidence to make a real-device latency claim; do not infer that concurrent network errors caused keyboard jank merely because windows overlap. Commit the docs/evidence separately as `docs(diagnostics): document private correlation and limits`.

## Self-review checklist

- [ ] All client data fields are closed and bounded; no handle, message text, query text, room ID, raw exception, or token is accepted or logged.
- [ ] The server derives refs only after authentication; current handle lookup is exact and private; production requires a dedicated secret.
- [ ] The anonymous startup endpoint stays anonymous; old clients and old log lines still work; new clients fall back once on older receiver 422.
- [ ] Generic triage/network exports strip refs; private output reports actual log coverage and uncertainty, not a claimed seven-day completeness or causal diagnosis.
- [ ] Time overlap is confined to a validated same-device ref; direct request UUID wins; `docker logs --timestamps` and the root-only maintenance TTY/stdin workflow are tested with the matching candidate DTO source.
- [ ] The companion search/room plan owns hot-path instrumentation; this plan supplies its tested wire and time-anchor contract without concurrent edits to shared files.
