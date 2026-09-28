# Local Chat Search Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make room and global chat searches show local results promptly and finish under continuous incoming messages without missing, repeating, or exposing messages that were withdrawn.

**Architecture:** Each room query owns a bounded, device-local event-ID snapshot and reads message rows in one SQLCipher batch per page; ordinary new events do not reset that query. Work is published after a bounded scan slice, while security changes still invalidate or remove visible content immediately. Global search keeps its last result during ordinary index appends and publishes only the newest asynchronous query generation.

**Tech Stack:** Flutter/Dart, vendored Matrix SDK `MatrixSdkDatabase`, SQLCipher via `sqflite`, Flutter widget and FFI tests. No server-side search or plaintext diagnostic fields.

---

## File map and ownership

| Owner | Files | Responsibility |
| --- | --- | --- |
| SDK read boundary | `apps/mobile_flutter/third_party/matrix/lib/src/database/matrix_sdk_database.dart`; `apps/mobile_flutter/test/features/matrix/local_history_sdk_adapter_test.dart` | Fixed event-ID read window and one batch lookup preserving missing-row positions. This owner must finish before the room scanner owner starts. The parallel Matrix write-amplification task also touches the SDK file; serialize these edits. |
| Room scan | `apps/mobile_flutter/lib/features/matrix/local_room_history_search.dart`, `local_room_history_snapshot.dart`, new `local_search_id_snapshot.dart`; their existing `local_room_history_search_test.dart`, `local_room_history_snapshot_test.dart`, `local_history_snapshot_reuse_test.dart`, `local_history_reuse_performance_test.dart` | Stable query cursor, ≤1024 scanned rows per result slice, cached ID-keyed pages, and explicit incomplete-coverage state. |
| Matrix lease and room UI | `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`, new `local_search_event_policy.dart`, `apps/mobile_flutter/lib/features/matrix/room_page.dart`, `apps/mobile_flutter/lib/ui/chat/chat_search_page.dart`; `local_history_sdk_adapter_test.dart`, new `local_search_event_policy_test.dart`, `chat_search_page_test.dart`, `chat_search_query_controller_test.dart` | Batch adapter, ordinary append versus security invalidation, stable visible rows, and refresh affordance. This owner begins after the room scan public interface is agreed. |
| Global search | `apps/mobile_flutter/lib/features/search/local_message_search_repository.dart`, `global_search_controller.dart`, `global_search_page.dart`; `global_search_controller_test.dart`, `global_search_cache_first_test.dart`, `global_search_persistence_test.dart`, `global_search_page_test.dart` | Coalesce ordinary appends, filter withdrawn hits synchronously, guard every asynchronous result publish. Independent of room scan after baseline restoration. |

The route-lease, Matrix transaction-write, and diagnostic protocol work in the approved specification have separate plans and owners. Do not edit their product files from this plan except the explicitly shared SDK read and lease files; serialize those shared files with their owners.

## Task 0: Restore and prove the Android 2190 baseline

The implementation worktree begins at remote `main`, which lacks `local_room_history_search.dart` and `local_room_history_snapshot.dart`. A passing test there would test the wrong program. The parent integration task must restore the 2190 mobile source and package dependencies from `C:/Users/Administrator/.codex/worktrees/diagnostic-fidelity/StarChat` before any RED test below. Use the immutable manifest `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json`; do not copy the entire dirty `D:` checkout.

- [ ] **Step 1: Check the exact inputs in the target worktree.** From PowerShell 7, set UTF-8 without BOM, then run this read-only preflight. It must print `True` for every listed path and `0.4.21+2190` for `apps/mobile_flutter/pubspec.yaml` after baseline restoration.

```powershell
$OutputEncoding = [Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
$repo = 'C:/Users/Administrator/.codex/worktrees/chat-search-jank/StarChat'
$manifest = Get-Content -LiteralPath 'D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json' -Encoding utf8 -Raw | ConvertFrom-Json
$paths = @(
  'apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart',
  'apps/mobile_flutter/lib/features/matrix/local_room_history_search.dart',
  'apps/mobile_flutter/lib/features/matrix/local_room_history_snapshot.dart',
  'apps/mobile_flutter/lib/features/matrix/chat_search_query_controller.dart',
  'apps/mobile_flutter/lib/ui/chat/chat_search_page.dart',
  'apps/mobile_flutter/lib/features/search/local_message_search_repository.dart',
  'apps/mobile_flutter/lib/features/search/global_search_controller.dart',
  'apps/mobile_flutter/lib/features/search/global_search_index.dart',
  'apps/mobile_flutter/third_party/matrix/lib/src/database/matrix_sdk_database.dart'
)
foreach ($path in $paths) {
  $entry = $manifest.files | Where-Object path -eq $path
  $actual = (Get-FileHash -LiteralPath (Join-Path $repo $path) -Algorithm SHA256).Hash.ToLowerInvariant()
  '{0} {1}' -f ($actual -eq $entry.sha256), $path
}
Select-String -LiteralPath (Join-Path $repo 'apps/mobile_flutter/pubspec.yaml') -Pattern '^version:'
```

- [ ] **Step 2: Stop if any input differs.** Restore that file from the 2190 frozen source only after verifying its SHA against the manifest; re-run Step 1. Record the baseline import as a separate commit so the later fix can be reviewed as a minimal delta from 2190. Run `git -C $repo diff --check` and confirm `apps/mobile_flutter/.dart_tool/package_config.json` and the lockfile exist before testing. Existing `--no-pub` tests avoid dependency drift.

## Task 1: Add batched ID reads and a bounded ID snapshot to the SDK

**Files:** Modify `apps/mobile_flutter/third_party/matrix/lib/src/database/matrix_sdk_database.dart`; test `apps/mobile_flutter/test/features/matrix/local_history_sdk_adapter_test.dart`. Keep `DatabaseApi` unchanged: production uses `MatrixSdkDatabase`, and changing the abstract API would require unrelated Hive implementations.

- [ ] **Step 1: Write the failing FFI test.** Extend the existing `LocalClient`/FFI fixture. Store IDs `e0` to `e3`, open a snapshot with `maxBytes: 8` to force low-memory mode, insert `e4` at the head, and assert the snapshot still returns `['e3','e2']` then `['e1','e0']`. Delete the stored `e2` row directly from `box_events` as the existing test does; assert a batch read of `['e3','e2']` returns `[Event, null]` in the same order. Reopen the database and repeat the assertions. The exact new calls are:

```dart
final ids = await db.openSearchEventIds(room, maxBytes: 8);
expect(await ids.page(0, 2), ['e3', 'e2']);
expect(await ids.page(2, 2), ['e1', 'e0']);
final rows = await db.getSearchEventsByIds(room, ['e3', 'e2']);
expect(rows.map((e) => e?.eventId), ['e3', null]);
ids.dispose();
```

- [ ] **Step 2: Verify RED.** From `apps/mobile_flutter`, run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/features/matrix/local_history_sdk_adapter_test.dart`. Expected: compile failure because `openSearchEventIds` and `getSearchEventsByIds` do not yet exist.

- [ ] **Step 3: Implement the SDK-only read methods.** `getSearchEventsByIds` must call `_eventsBox.getAll(keys)` once and preserve each null slot; `getEventList(start:)` is unsuitable because new head insertions shift its offset. `openSearchEventIds` reads the immutable Box value once. If the estimated `(8 + 2 * id.length)` bytes per ID fit within 32 MiB, copy the IDs into an immutable list. Above that budget, retain only the original first/last IDs and a page-offset→last-ID checkpoint map; on each page, find the checkpoint in the current immutable Box value and stop at the captured tail. Missing anchors, reordered interior rows, or a vanished tail throw a typed snapshot-invalidated error instead of returning false emptiness. Add the following public surface in the SDK file and keep its implementation local to that file:

```dart
Future<MatrixSearchEventIds> openSearchEventIds(Room room,
    {int maxBytes = 32 * 1024 * 1024});
Future<List<Event?>> getSearchEventsByIds(Room room, List<String> eventIds);

final class MatrixSearchEventIds {
  Future<List<String>> page(int offset, int limit);
  void dispose();
}
```

For the batch lookup, use `TupleKey(room.id, id).toString()` for each key and `Event.fromJson(copyMap(raw), room)` only when the aligned raw value is a map. A zero or negative page limit returns `[]`; `dispose` clears retained IDs and checkpoints. The low-memory page algorithm must validate `offset == 0` against the captured first ID and subsequent offsets against the previous page's checkpoint; its captured last ID is inclusive. This is a real bounded fallback, not a `getEventIdList()` full copy on each page.

- [ ] **Step 4: Verify GREEN and commit.** Run the same FFI test and `& 'C:/src/flutter/bin/flutter.bat' analyze --no-pub lib/features/matrix/matrix_e2ee_client.dart third_party/matrix/lib/src/database/matrix_sdk_database.dart test/features/matrix/local_history_sdk_adapter_test.dart`. Expected: test passes, analyzer exits 0. Commit only the SDK read method and focused test. Coordinate with the Matrix write task before touching the shared SDK file.

## Task 2: Make room search return a stable, partial page

**Files:** Create `apps/mobile_flutter/lib/features/matrix/local_search_id_snapshot.dart`; modify `local_room_history_search.dart` and `local_room_history_snapshot.dart`; test `local_room_history_search_test.dart`, `local_room_history_snapshot_test.dart`, `local_history_snapshot_reuse_test.dart`, `local_history_reuse_performance_test.dart`.

- [ ] **Step 1: Write RED tests using a fake ID snapshot.** In `local_room_history_search_test.dart`, supply 10,000 ordered IDs and a batch row reader. Search for one hit at row 9,000 while appending 50 newer IDs between pages. Assert the first `search()` returns within two 512-row scans with `items.isEmpty` and a non-null `nextCursor`, the automatic continuation eventually returns the old hit, no ID repeats, and the 50 new IDs are excluded until a fresh query. Force `sourceRevision` to change during an awaited read and assert the old plaintext is never published. Existing `revision change during DB await` and `source revision rereads off-window recall` tests remain green.

```dart
final first = await search.search(const ChatSearchFilters(keyword: 'needle'));
expect(first.items, isEmpty);
expect(first.nextCursor, isNotNull);
expect(scannedRows, lessThanOrEqualTo(1024));
// Append 50 IDs to the live source without changing the safety revision.
final seen = <String>{};
var page = first;
while (page.nextCursor != null) {
  page = await search.search(const ChatSearchFilters(keyword: 'needle'),
      cursor: page.nextCursor);
  for (final item in page.items) expect(seen.add(item.eventId), isTrue);
}
expect(seen, contains('e9000'));
expect(seen.where((id) => id.startsWith('new-')), isEmpty);
```

- [ ] **Step 2: Verify RED.** Run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/features/matrix/local_room_history_search_test.dart`. Expected: the old scanner waits for a hit or EOF and violates the ≤1024-row assertion; it also lacks the frozen-ID callbacks.

- [ ] **Step 3: Implement the small snapshot interface and scanner.** Add this app-side interface so synthetic tests do not depend on the SDK concrete class:

```dart
abstract interface class LocalSearchIdSnapshot {
  Future<List<String>> page(int offset, int limit);
  void dispose();
}
```

Add optional, paired `openIds` and `readByIds` callbacks to `LocalRoomHistorySearch` while retaining its existing `readPage` constructor for calendar and older test fixtures. Open one ID handle per logical source at the beginning of a new query; `cancel()` disposes handles. For the frozen path, read exactly the IDs returned by `handle.page(state.offset, 512)` and preserve a missing message row as `isDisplayable=false`/`isUndecrypted=true`. The scanner increments `visited` after each examined row and returns a slice when `visited >= 1024`, even if the slice contains fewer than 50 hits or zero hits. On an unfinished source without a matching head, do not merge another source's candidate across it; return the already proven sorted hits with a continuation cursor. Check safety revision and query generation after every await and every 64 rows. Only report `nextCursor: null` when every source is exhausted.

- [ ] **Step 4: Preserve page reuse without weakening invalidation.** In `LocalRoomHistorySnapshot`, add `pageByIds(roomId, ids, readByIds)` with an LRU key including room ID, first/last ID, count, and safety generation. Reuse the existing 200,000-row/64 MiB budget for both offset and ID pages. A security clear removes both; an ordinary append invalidates calendar date metadata and offset pages but retains immutable ID pages. `LocalRoomHistorySearch` uses `pageByIds` for production batch reads. Existing cached-keyword-change tests must show no extra DB projection when a user edits the query on unchanged history.

- [ ] **Step 5: Verify GREEN and commit.** Run the four focused test files listed in this task with `flutter.bat test --no-pub`, then targeted `flutter.bat analyze --no-pub` over the four product/test files. Expected: all focused tests pass; sparse first result is partial rather than a long blocking scan; hidden/redacted/undecrypted coverage behavior remains intact. Commit only this scanner/snapshot batch.

## Task 3: Split ordinary appends from security invalidation and wire room UI

**Files:** Create `apps/mobile_flutter/lib/features/matrix/local_search_event_policy.dart`; modify `matrix_e2ee_client.dart`, `room_page.dart`, `chat_search_page.dart`; test new `apps/mobile_flutter/test/features/matrix/local_search_event_policy_test.dart`, existing `local_history_sdk_adapter_test.dart`, `chat_search_page_test.dart`, `chat_search_query_controller_test.dart`, `local_history_clear_test.dart`.

- [ ] **Step 1: Write RED policy and widget tests.** A new timeline message, its later decryption, ephemeral receipt, or account-data update must not increment the search safety revision. Redaction, `m.replace`, local history clear, retained-room source change, lease revocation, and account switch must increment it. For the widget, show a hit, signal 50 ordinary appends, and assert the same hit stays visible, the query callback was not called again, and a small `有新消息，点击更新` control appears. Tap it and assert exactly one fresh query. Signal a redaction/security change and assert the old hit disappears before any asynchronous rescan completes.

```dart
final before = queries;
for (var i = 0; i < 50; i++) ordinaryAppends.value++;
await tester.pump();
expect(queries, before);
expect(find.byKey(const Key('chat-search-result-old')), findsOneWidget);
await tester.tap(find.byKey(const Key('chat-search-refresh-new')));
await tester.pump(const Duration(milliseconds: 300));
expect(queries, before + 1);
securityChanges.value++;
await tester.pump();
expect(find.byKey(const Key('chat-search-result-old')), findsNothing);
```

- [ ] **Step 2: Verify RED.** Run `flutter.bat test --no-pub test/features/matrix/local_search_event_policy_test.dart test/ui/chat/chat_search_page_test.dart`. Expected: the new policy/append input is absent and ordinary history notifications still clear the page.

- [ ] **Step 3: Implement the event policy.** `EventUpdateType.ephemeral`, `accountData`, `state`, and `inviteState` do not affect search. A new `timeline` event with a nonempty event ID and no `redacts` or `m.replace` relation is an append; keep at most 4096 such IDs in a recent-ID set. A `decryptedTimelineQueue` event is an append only if its ID is in that set. `history`, redaction, edit/replacement, unknown ID, or a previously known old event is a security invalidation. The explicit API is:

```dart
enum LocalSearchEventEffect { none, append, invalidate }

final class LocalSearchEventPolicy {
  LocalSearchEventEffect classify(EventUpdate update);
  void clear();
}
```

The policy must check `content['m.relates_to']` or the event's `content['m.relates_to']` map for `rel_type == 'm.replace'`, and both top-level and nested `redacts`; do not log either map. Bounded recent IDs are cleared when the lease is revoked or the account changes.

- [ ] **Step 4: Wire the lease and UI.** Add `localHistoryAppends` and `localHistoryCalendarChanges` listenables to `MatrixRoomLease`; keep `localHistoryChanges` as the security-only signal. An ordinary append invalidates calendar offset/date data but not the search safety revision or frozen ID handles. In `RoomPage`, construct `LocalRoomHistorySearch` with `openIds` and `readByIds` adapters around the Task 1 SDK APIs; pass safety, append, and calendar signals separately to `ChatSearchPage`. On append, the search page sets one boolean badge and leaves `_lastPage`, cursor, and `_state` unchanged. Tapping the badge invokes `_execute` once and clears the badge. On security signal, immediately clear visible plaintext, cancel the query, and run the existing guarded retry. Calendar uses its calendar signal so newly arrived dates can appear without forcing the active text search to restart.

- [ ] **Step 5: Verify GREEN and commit.** Run the five focused files listed above plus `test/ui/chat/local_history_calendar_autoload_test.dart` and `test/features/matrix/local_room_history_snapshot_test.dart`; run targeted analyzer over the touched files. Expected: all pass; an ordinary incoming burst leaves the current query and its scroll position intact, while withdrawal removes old text synchronously. Commit the lease/UI files together only after the room scanner API is green.

## Task 4: Coalesce global search appends and reject stale async publishes

**Files:** Modify `apps/mobile_flutter/lib/features/search/local_message_search_repository.dart`, `global_search_controller.dart`, `global_search_page.dart`; test `global_search_controller_test.dart`, `global_search_cache_first_test.dart`, `global_search_persistence_test.dart`, `global_search_page_test.dart`, `bug_e1_search_index_incremental_test.dart`.

- [ ] **Step 1: Write RED tests.** Index 10,000 text messages, submit one query, and append 50 messages. Count `loadRooms` and `index.search`: neither may run again merely because the 50 appends arrived. Results remain visible with an update affordance; explicit refresh recalculates once. Remove a matched event and assert it disappears immediately without a full scan; `attachAccount`/`clear` immediately removes all old-account hits. Hold `_aggregateConversations` behind a `Completer`, start a newer query, release the old one, and assert the stale generation never changes results or `loading`. Retain the existing test that a slow contacts loader cannot block local room/message hits.

```dart
final before = roomLoads;
for (var i = 0; i < 50; i++) {
  repository.recordRoomMessages([incoming(i)]);
}
expect(roomLoads, before);
expect(controller.results.conversations, isNotEmpty);
expect(controller.hasNewLocalResults, isTrue);
await controller.refresh();
expect(roomLoads, before + 1);
```

- [ ] **Step 2: Verify RED.** Run `flutter.bat test --no-pub test/features/search/global_search_controller_test.dart test/features/search/global_search_cache_first_test.dart`. Expected: `GlobalSearchController._onLocalHistoryChanged` currently starts a new `refresh()` for every repository notification and has no `hasNewLocalResults`.

- [ ] **Step 3: Add typed local-change semantics.** Expose an immutable `LocalSearchRepositoryChange` with `append`, `remove(Set<String> ids)`, and `reset` kinds. Set it immediately before the existing `notifyListeners()` calls in `recordRoomMessages`, successful backfill, `removeMessages`, `attachAccount`, and `clear`. On append, `GlobalSearchController` sets `hasNewLocalResults` once without rescanning. On remove, reconstruct only the currently visible `GlobalSearchConversationHit` lists after filtering removed event IDs; discard empty groups. On reset, clear `results`, cancel the pending debounce, increment `_epoch`, set `loading=false`, and notify. A query edit or explicit refresh consumes the append flag and performs one normal query.

- [ ] **Step 4: Guard asynchronous result publication.** Make the local `publish()` helper in `GlobalSearchController.refresh` compute a `GlobalSearchResults` value without assigning `results`. After every awaited `loadRooms`, `_aggregateConversations`, and `loadContacts`, check `epoch == _epoch && !_disposed` before assigning results or loading. Keep local results visible while contacts are still waiting or fail. In `GlobalSearchPage`, show a compact update button when `hasNewLocalResults` and a nonblank query coexist; clicking it calls `controller.refresh()` once.

- [ ] **Step 5: Verify GREEN and commit.** Run all five focused files listed in this task, `flutter.bat analyze --no-pub` on touched product/test paths, then commit this independent global-search batch.

## Task 5: Integrate, measure, and stop on an unmet performance target

**Files:** Tests above; verification evidence only under `docs/verification/artifacts/2026-09-28/`; task record and verification summary owned by the parent integration task.

- [ ] **Step 1: Run the exact joint regression.** In `apps/mobile_flutter`, use `& 'C:/src/flutter/bin/flutter.bat' test --no-pub` with the room SDK adapter, room scanner, snapshot reuse, room widget, global controller, global page, and account-switch tests from Tasks 1–4. Expected: exit 0. Run `& 'C:/src/flutter/bin/flutter.bat' analyze --no-pub`; expected exit 0. Preflight SDK/Java/disk and `.env` before `pwsh -NoProfile -File scripts/verify.ps1`; follow `mobile-delivery-workflow.md` evidence reuse for unchanged gates and preserve any unrelated baseline failures verbatim.

- [ ] **Step 2: Check security and completeness under load.** Run a synthetic 10,000-ID sparse hit at row 9,000, a 100,000-ID no-hit scan, and 50 incoming appends while searching. Assert: first call scans ≤1024 rows, every continuation cursor advances, no repeated/missing pre-snapshot ID, `nextCursor` becomes null only at complete local coverage, and a redaction/local-clear/account switch makes old text unreachable immediately. The 32 MiB branch must be exercised with a tiny `maxBytes` fixture, not assumed from ordinary 100,000-ID memory use.

- [ ] **Step 3: Compare on Android with frozen inputs.** Record build SHA, exact test corpus and decryption coverage, first-result P50/P95, complete-coverage P50/P95, UI build/raster frames, peak memory/GC, and DB batch count for 2190 versus candidate. The approved thresholds are Redmi K80 near-hit first result P95 ≤500 ms, 10,000 sparse complete coverage P95 ≤3 s, 100,000 complete coverage P95 ≤10 s, and zero query restarts during 50 appends. A host FFI or emulator timing is diagnostic only; it cannot satisfy the K80 gate.

- [ ] **Step 4: Apply the required index decision gate.** If the same-device P95 thresholds fail after the stable snapshot and bounded scanner, stop release of this search fix. In this task, design a rebuildable substring index **inside the existing SQLCipher account database**, specify Chinese/English substring behavior, bounded background backfill, event-ID deletion on withdrawal, account purge, database upgrade/rollback, and no plaintext outside SQLCipher; obtain the E2EE domain and Quality/Security reviews required by `AGENTS.md`, add a concrete index implementation task to this plan, then repeat the RED/GREEN and same-device gate. Do not label a partial first page as complete-history speed or claim the issue fixed from host milliseconds alone.

- [ ] **Step 5: Review in order.** Run specification-compliance review, then quality/security review. The parent integration owner records the exact source/input hashes, commands, exits, limits, and real-device gap in the task ledger before any Android candidate is built. Production update and signing belong to the release plan, not to this search code plan.
