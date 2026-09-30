# Room Lifecycle and Matrix Burst Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release each closed room's Matrix lease and reduce a 50-message sync burst in one room from 50 full timeline-fragment writes to one, without losing encrypted local history or changing event order.

**Architecture:** Keep the existing Matrix SDK and SQLCipher schema. Make a room lease's slow owner drain independent of the global lifecycle admission queue, then cancel the lease from the route's `finally` after page disposal. Coalesce only `box_timeline_fragments` puts inside one native SQLite batch; preserve transaction reads through the box cache and invalidate caches on action or commit failure. Keep web IndexedDB behavior and the SDK database version unchanged.

**Tech Stack:** Flutter/Dart, vendored Matrix 0.34.0, `sqflite_common_ffi`, SQLCipher, Flutter tests, PowerShell 7.

---

## File map and ownership

- `apps/mobile_flutter/lib/app_home.dart`: owns a room-route lease from acquisition through every exit path.
- `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`: makes room-lease revocation immediate and its drain single-flight, without holding the global lifecycle queue while pending page operations finish.
- `apps/mobile_flutter/third_party/matrix/lib/src/database/sqflite_box.dart`: native-only, transaction-scoped coalescing for timeline fragments and cache invalidation on failed batches.
- `apps/mobile_flutter/third_party/matrix/lib/src/database/matrix_sdk_database.dart`: remains on database version 9 and continues to own the existing event order and ACK logic. Do not add a schema migration or change its `storeEventUpdate` rules.
- `apps/mobile_flutter/test/features/matrix/matrix_room_timeline_adapter_test.dart`: real `MatrixSdkE2eeClient` lease drain/admission regression.
- `apps/mobile_flutter/test/features/matrix/room_navigation_coordinator_test.dart`: route replacement, failure, and distinct-room entry behavior.
- `apps/mobile_flutter/test/features/matrix/sdk_receive_burst_benchmark_test.dart`: real SQLite batch-write count, byte count, replay, and reopen verification.
- `apps/mobile_flutter/test/features/matrix/cooperative_matrix_database_test.dart`: nested transaction, action/commit failure, ACK, and redaction regression.
- `docs/verification/artifacts/2026-09-28/chat-search-jank/`: commands, frozen identity, RED/GREEN logs and source hashes only. Do not place artifacts at repository root.

## Task 0: Restore the actual Android 2190 source baseline

- [ ] **Step 1: Compare the target worktree with the released input.** From `C:/Users/Administrator/.codex/worktrees/chat-search-jank/StarChat`, use the 2190 frozen list at `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json`. In PowerShell 7, after setting console/pipeline UTF-8 and Python UTF-8 environment variables, parse `files` and check SHA-256 for the seven source/test paths above plus `apps/mobile_flutter/pubspec.lock`. Save a path/hash/difference report in the task artifact directory. The released SDK database file has SHA-256 `c71b64f59537190b05f6130adde1521f30995f3ce0f67e6582b58f17a3bc5a81`; do not silently mix an unrelated room-preview repair into the baseline.
- [ ] **Step 2: Restore the complete verified 2190 mobile input first.** The parent delivery plan copies only paths named by the r3 frozen manifest from `diagnostic-fidelity`, after checking every source SHA-256. It then verifies every destination SHA-256 and commits that baseline. Do not run this room plan's RED tests before the parent's 1793/1793 verification and baseline commit; do not repeat partial file restoration here.
- [ ] **Step 3: Record the frozen state.** Run `git status --short`, `flutter --version`, `dart --version`, and the focused SHA comparison again. If a required file has no verified source, stop this task before writing a RED test; report the missing path and its frozen SHA to the root task.

## Task 1: Prove and fix room-lease ownership

- [ ] **Step 1: Add failing lease tests.** In `matrix_room_timeline_adapter_test.dart`, use a `Client` subclass whose `getRoomById` returns two synthetic `Room`s. Create `MatrixSdkE2eeClient` with the existing `_continuity` test helper. Open A, bind A's owner drain to `Completer<void>().future`, start `final closing = a.cancel()`, and immediately attempt `owner.openRoomLease(b.id).timeout(const Duration(milliseconds: 500))`. Assert B opens before A's held drain completes; then complete the drain and await both cancellations. This fails today because `_cancelManagedResource` awaits A's drain inside `_serializeLifecycle`. Add a repeated-open/close assertion using the existing `owner.debugManagedResourceCount` getter: after each release it returns the initial count. Add one test that cancels the same lease twice and one that suspends while the drain is pending.
- [ ] **Step 2: Run RED.** From `apps/mobile_flutter`, run `flutter test --no-pub test/features/matrix/matrix_room_timeline_adapter_test.dart --plain-name 'slow room lease drain does not block another room'`. Expected: timeout before B opens. Save the actual exit code and output.
- [ ] **Step 3: Implement two-phase room cancellation.** In `matrix_e2ee_client.dart`, keep generic `_cancelManagedResource` for non-room resources. Change `MatrixRoomLease.cancel()` to single-flight through a new `owner._cancelRoomLease(this)`. In that method set `lease.canceled = true` and call `lease.revokeNow()` before awaiting `lease.detach()` **outside** `_serializeLifecycle`; only after successful drain, enter `_serializeLifecycle` to remove that exact lease from `_managedResources`. Make `detach()` single-flight so concurrent suspend and route close await the same drain. A failed drain must leave the revoked lease managed and make `cancel()` retryable, never revive it on resume. Preserve the existing fixed `E2EE_ROOM_LEASE_DRAIN_TIMEOUT`/`FAILED` diagnostics, without logging room IDs or raw errors.

```dart
Future<void> _cancelRoomLease(MatrixRoomLease lease) async {
  lease.canceled = true;
  lease.revokeNow();
  await lease.detach();
  await _serializeLifecycle(() async {
    _managedResources.remove(lease);
  });
}
```

The lease's `cancel()` and `detach()` keep their own nullable in-flight futures; clear an in-flight future in `whenComplete`, and set a separate success flag only after removal. `attach()` already skips `canceled` leases. Do not move `_suspendWithinLifecycle` or E2EE identity checks.

- [ ] **Step 4: Own the route lease in AppHome.** Declare `MatrixRoomLease? routeLease` before `_openManagedRoomRoute`'s `try`, assign immediately after `openRoomLease`, and use that variable throughout route setup. In its `finally`, first release the route registry and notify the caller that the page closed, then `await routeLease?.cancel()` after `await route.completed`/page disposal. For a failure before route push, cancel the acquired lease in the same `finally`. Catch cancellation failure only to emit a fixed diagnostic category and preserve the original route error; do not mark a failed drain as released. The `!mounted` branch must rely on this one `finally` instead of calling `cancel()` twice. Do not cancel any independently acquired outbox or history lease.

```dart
MatrixRoomLease? routeLease;
try {
  routeLease = await widget.matrix.openRoomLease(roomId);
  final lease = routeLease;
  if (!mounted) return;
} finally {
  StatisticsRoomScope.leave(roomId);
  final finalRoute = route;
  if (finalRoute != null) handle.release(finalRoute);
  navigationRequests?.dispose();
  notifyClosed();
  final owned = routeLease;
  if (owned != null) {
    try {
      await owned.cancel();
    } catch (_) {
      debugPrint('[chatflow/perf] room_lease_cancel_failed');
    }
  }
}
```

- [ ] **Step 5: Run GREEN and adjacent route checks.** Run `flutter test --no-pub test/features/matrix/matrix_room_timeline_adapter_test.dart test/features/matrix/room_navigation_coordinator_test.dart test/features/matrix/offline_first_opening_test.dart`. Expected: all pass, including replacement, slow A release/B open, cancellation during suspend, and resource count returning to baseline. If the real `AppHome` route cannot be driven by the existing tests, add a widget regression that opens, pops and replaces a room and observes `debugManagedResourceCount`; do not rely only on a source-text assertion.
- [ ] **Step 6: Commit only these files and their tests.** `git add apps/mobile_flutter/lib/app_home.dart apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart apps/mobile_flutter/test/features/matrix/matrix_room_timeline_adapter_test.dart apps/mobile_flutter/test/features/matrix/room_navigation_coordinator_test.dart` followed by `git commit -m "fix: release closed room leases"` after reviewing staged diff.

## Task 2: Prove native batch failure behavior before coalescing

- [ ] **Step 1: Write RED tests in `cooperative_matrix_database_test.dart`.** Use the existing real FFI SQLite fixture. Warm `getEventList`, then cause `database.transaction(() async { await fixture.store(message); throw StateError('synthetic'); })` and assert an immediate in-memory read and a reopened read both exclude that event. Repeat with `PRAGMA query_only = ON` so `Batch.commit` fails, then turn it off and assert a later ordinary `storeEventUpdate` persists. Add a nested transaction case: an inner SDK transaction and an outer transaction must share one atomic commit; an inner error caught by the outer action still prevents outer commit. Assert in-memory and reopened results. These tests must fail against the current `_activeBatch`/cache cleanup path for the intended reason.
- [ ] **Step 2: Run RED.** `flutter test --no-pub test/features/matrix/cooperative_matrix_database_test.dart --plain-name 'failed native batch restores cache and writer state'`. Expected: stale cached event or a later write missing from disk; capture actual output.
- [ ] **Step 3: Repair `sqflite_box.dart` transaction state.** Keep one active native batch for nested SDK transactions in the same zone; a nested error poisons the outer batch even if a caller catches it. Put `_activeBatch` reset in `finally`, not after `await action()`. On an action or `Batch.commit` failure, clear the caches and cached-key sets of every opened box before releasing the zone lock; this makes the next read authoritative from SQLite and avoids retaining uncommitted plaintext in memory. A successful batch retains its normal caches. No persistent schema or version change.

```dart
return zoneTransaction(() async {
  if (_activeBatch != null) {
    try {
      return await action();
    } catch (_) {
      _batchPoisoned = true;
      rethrow;
    }
  }
  final batch = _db.batch();
  _activeBatch = batch;
  try {
    await action();
    if (_batchPoisoned) throw StateError('Nested database action failed');
    await batch.commit(noResult: true);
  } catch (_) {
    for (final invalidate in _cacheInvalidators) invalidate();
    rethrow;
  } finally {
    _activeBatch = null;
    _batchPoisoned = false;
  }
});
```

Register each `Box`'s `_cache.clear()`/`_cachedKeys = null` invalidator in `openBox`. A nested success now joins the outer batch instead of committing halfway; assert that deliberate change in the test. Do not swallow the original action/commit exception.

- [ ] **Step 4: Run GREEN.** `flutter test --no-pub test/features/matrix/cooperative_matrix_database_test.dart`. Expected: all pass, including real DB reopen, nested failure and a subsequent successful write.
- [ ] **Step 5: Commit.** Stage only `sqflite_box.dart` and `cooperative_matrix_database_test.dart`; `git commit -m "fix: restore matrix box caches after failed batch"`.

## Task 3: Coalesce only timeline-fragment puts in a native transaction

- [ ] **Step 1: Turn the existing measurement into RED.** In `sdk_receive_burst_benchmark_test.dart`, replace `expect(counter.timelineFragmentWrites, burstIds.length)` with `expect(counter.timelineFragmentWrites, 1)` for each 1,500/10,000 history fixture. Also assert `counter.serializedBytes == finalListBytes` for the completed batch, then replay the 50 events and assert no additional fragment write. Add a second-room fixture to assert one write per affected room, not one global write. Add ACK (`transaction_id`), history append, redaction and duplicate sync assertions using the fixture's real `getEventList` before and after reopen.
- [ ] **Step 2: Run RED.** `flutter test --no-pub test/features/matrix/sdk_receive_burst_benchmark_test.dart`. Expected: fragment-write count 50 rather than 1. Save the actual count, bytes and exit code; the old synthetic 10k/50 figure was about 6.46 MB, not a Redmi K80 measurement.
- [ ] **Step 3: Stage native fragment puts.** In `sqflite_box.dart`, add a transaction-local ordered map keyed by fragment `k`. Inside `Box<List>.put`, when `_activeBatch != null && name == 'box_timeline_fragments'`, store a closure that calls `batch.insert` with the **final** list's `_toString(val)` at flush time; overwrite an earlier closure for the same key. Update `_cache[key]` immediately so repeated `storeEventUpdate` and `getEventList` inside the same transaction see the latest list. Flush these closures exactly once before `batch.commit`. Outside a transaction retain the current immediate put behavior. Keep this branch limited to the timeline box, not event bodies, keys or other Matrix tables.

```dart
if (txn != null && name == 'box_timeline_fragments') {
  boxCollection._pendingTimelinePuts[key] = () => txn.insert(
    name,
    {'k': key, 'v': _toString(val)},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  _cache[key] = val;
  _cachedKeys?.add(key);
  return;
}
```

At transaction flush call each pending closure once. In `Box.delete`, `deleteAll` and `clear`, remove affected pending keys before queueing deletes so an earlier deferred put cannot resurrect a removed fragment. In `getAllKeys`, union pending keys with the DB result; in `getAll`, overlay cached values for pending keys after the DB query. Clear pending closures in the same `finally` as `_activeBatch`. A failed batch uses Task 2 cache invalidation. Preserve timeline order rules in `matrix_sdk_database.dart` and do **not** increment `MatrixSdkDatabase.version` (its default upgrade clears events/fragments).

- [ ] **Step 4: Run GREEN and adjacency.** Run `flutter test --no-pub test/features/matrix/sdk_receive_burst_benchmark_test.dart test/features/matrix/cooperative_matrix_database_test.dart test/features/matrix/sdk_ack_order_test.dart test/features/matrix/sdk_history_fragment_test.dart`. Expected: batch write count 1 per changed fragment, serialized bytes equal one final array, replay 0 new fragment writes, ACK/history/redaction order correct both before and after reopen, rollback tests still pass. The active event-loop heartbeat test must continue to pass; one expensive single event remains non-preemptible and is not claimed fixed.
- [ ] **Step 5: Commit.** Stage only `sqflite_box.dart` and the affected Matrix tests; `git commit -m "perf: coalesce matrix timeline fragment writes"`.

## Task 4: Verification and delivery boundary

- [ ] **Step 1: Run focused static analysis.** From `apps/mobile_flutter`, run `dart analyze lib/app_home.dart lib/features/matrix/matrix_e2ee_client.dart third_party/matrix/lib/src/database/sqflite_box.dart test/features/matrix/matrix_room_timeline_adapter_test.dart test/features/matrix/cooperative_matrix_database_test.dart test/features/matrix/sdk_receive_burst_benchmark_test.dart`. Expected exit code 0. Then run the focused Flutter tests from Tasks 1–3 without relying on a cached previous result after a source edit.
- [ ] **Step 2: Run the repository gate after preflight.** Check `.env` presence, Flutter/Java/SDK identity, disk and the frozen source list. Then run `pwsh -NoProfile -File scripts/verify.ps1` from the worktree root if the inputs are available. Save command, actual exit code, source hash and first failure. Reuse an equivalent completed gate only when the mobile workflow's unchanged-input rules permit it.
- [ ] **Step 3: Measure on a device without changing account data.** On the available Android simulator, use identical local 10k-history/50-message fixtures for 2190 and the candidate. Capture UI/raster frame time, route open/close duration, Dart CPU/GC, fragment SQL write count and sync-processing duration; compare medians and P95. Redmi K80 is user-owned and has no captured profile, so report its result as pending instead of extrapolating simulator timing.
- [ ] **Step 4: Review and hand off.** Run specification-compliance review before quality/security review. Confirm no message content, keys or room IDs in diagnostics; confirm same SQLCipher file and Matrix event ordering. Record RED/GREEN evidence and remaining K80/Android release steps in this task's verification record. The search and authenticated-diagnostic tasks have separate owners and plans; do not claim this room/SDK batch alone completes those objectives.
