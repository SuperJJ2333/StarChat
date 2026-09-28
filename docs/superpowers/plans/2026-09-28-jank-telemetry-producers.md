# Keyboard, Room, and Sync Burst Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure keyboard show/hide, local room enter/leave, and incoming sync bursts with bounded, content-free stages so a test account's UI stalls can be compared with actual network and Matrix processing time.

**Architecture:** Use the closed performance wire in `2026-09-28-account-diagnostics-correlation.md`. UI producers read focus, view insets, route completion, and frame callbacks without awaiting the network; the sync producer counts raw timeline envelopes from the existing `Client.onSync` stream and attaches that count to its existing `matrix_sync` trace. Existing `conversation_open` and `matrix_sync` phase traces remain intact, while new route/keyboard operations isolate visible UI latency.

**Tech Stack:** Flutter/Dart, `PerformanceTraceRecorder`, `WidgetsBinding`, `Navigator`, Matrix SDK public streams, Flutter widget/unit tests.

---

## Baseline and file ownership

Read `docs/runbooks/mobile-delivery-workflow.md`, `docs/workflow/current-state.md`, the approved `docs/superpowers/specs/2026-09-28-chat-search-jank-diagnostics-design.md`, and the linked task record. The 2190 release manifest is `docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json` in the main checkout. Read-only inspection of `C:/Users/Administrator/.codex/worktrees/diagnostic-fidelity/StarChat` confirmed exact 2190 hashes for `app_home.dart` (`237715a4…`), `room_page.dart` (`e0c580ae…`), `matrix_sync_phase_metrics.dart` (`2359b9b9…`), `performance_trace.dart` (`acfcf470…`), `performance_trace_model.dart` (`c3d68813…`), and `chat_diagnostics.dart` (`ca576fbc…`). The implementation worktree was then restored to the 2190 baseline; verify its current hashes before RED. This plan does not authorize changes to the vendored Matrix SDK, search logic, or navigation ownership fixes.

The room agent owns `apps/mobile_flutter/lib/app_home.dart` first. The search agent owns `apps/mobile_flutter/lib/features/matrix/room_page.dart` until its search tests are complete. Add the minimal producer hooks to those files only after both owners release them. The diagnostic protocol agent owns `performance_trace_model.dart`, `performance_trace.dart`, receiver schema, and spool before producer integration. Do not edit those files concurrently; this plan consumes its `keyboard_direction`, `room_route_phase`, `timeline_event_count`, UTC window, and closed stage names. The SDK batch-write agent owns fragment persistence; use only a reviewed public callback for fragment-write aggregate if that agent exposes one.

At the start of each PowerShell session set BOMless UTF-8 console/pipeline encodings and `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8` as required by `AGENTS.md`. Run Flutter commands from `apps/mobile_flutter` with `--no-pub` after dependency preflight.

## Task 1: Keyboard transition state machine, without UI hooks

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/room_keyboard_transition_probe.dart`
- Create: `apps/mobile_flutter/test/features/matrix/room_keyboard_transition_probe_test.dart`

- [ ] **Step 1: Write RED tests.** Inject `PerformanceTraceRecorder`, `bottomInset`, monotonic clock, frame scheduler, and timeout scheduler. A show request begins only when bottom inset is zero; a hide request begins only when it is positive. `onMetricsChanged` followed by two post-layout frames within 1 logical pixel closes the trace with stages `keyboard_requested` and `keyboard_stable_frame` and direction `show` or `hide`. A system-back keyboard hide that leaves the input focused is detected from a falling inset even without an explicit hide request; its start is the first observed inset change, so it must not be compared with input-tap latency. One newly requested direction cancels the previous trace. A hardware keyboard with no inset change times out as `cancelled`, never `slow`; background/dispose cancels and removes callbacks. A second tap while a transition is active does not create a second operation. The probe never invokes an HTTP client or scans messages.

```dart
test('show closes only after the inset is stable for two frames', () {
  var inset = 0.0;
  final frames = <VoidCallback>[];
  final records = <PerformanceRecord>[];
  final recorder = PerformanceTraceRecorder(
    metrics: PerformanceMetrics(enabled: true),
    clockUs: () => 1000,
    onRecord: records.add,
  );
  final probe = RoomKeyboardTransitionProbe(
    recorder: recorder,
    bottomInset: () => inset,
    afterFrame: frames.add,
  );
  probe.request(KeyboardDirection.show);
  inset = 288;
  probe.onMetricsChanged();
  frames.removeAt(0)();
  expect(records, isEmpty);
  frames.removeAt(0)();
  expect(records.single.keyboardDirection, KeyboardDirection.show);
  expect(records.single.stagesUs.keys.last, PerformanceStage.keyboardStableFrame);
});
```

- [ ] **Step 2: Verify RED.** Run `flutter test --no-pub test/features/matrix/room_keyboard_transition_probe_test.dart`; expect the missing `RoomKeyboardTransitionProbe`/direction contract to fail, with no unrelated test failure.

- [ ] **Step 3: Implement the pure probe.** `request(direction)` checks the current inset, starts one `PerformanceOperationType.keyboardTransition` trace, sets its closed direction, and marks `keyboardRequested`. Track the last inset. If `onMetricsChanged()` sees a falling inset with no active request, start a passive hide operation from that observation and mark the same fixed stages. It records no text and schedules a frame check. Each frame reads only `bottomInset`; finish after two stable target frames. A single 1200 ms timer closes the still-active trace as `cancelled`; a later frame cannot revive it. `dispose()` cancels timer and active trace. Bound the active probe to one trace and one pending frame callback, and make every callback generation-checked so a disposed route cannot emit late data.

```dart
void request(KeyboardDirection direction) {
  if (_disposed || _alreadyAtTarget(direction)) return;
  if (_trace != null) _finish(PerformanceResult.cancelled);
  _generation++;
  _trace = _recorder.start(PerformanceOperationType.keyboardTransition)
    ..keyboardDirection = direction
    ..mark(PerformanceStage.keyboardRequested);
  _timeout = Timer(const Duration(milliseconds: 1200),
      () => _finish(PerformanceResult.cancelled));
}
```

- [ ] **Step 4: Verify GREEN and commit the isolated helper.** Run `flutter test --no-pub test/features/matrix/room_keyboard_transition_probe_test.dart`; expect all cases to pass. Commit only these two files as `feat(diagnostics): measure keyboard inset transitions`.

## Task 2: Hook keyboard and route frames after room/search owners finish

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/room_route_frame_probe.dart`
- Modify after ownership handoff: `apps/mobile_flutter/lib/app_home.dart`
- Modify after ownership handoff: `apps/mobile_flutter/lib/features/matrix/room_page.dart`
- Create: `apps/mobile_flutter/test/features/matrix/room_route_frame_probe_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/room_open_performance_trace_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/room_page_anchor_navigation_test.dart`

- [ ] **Step 1: Write RED route tests.** At route push, a `room_local_frame`/`enter` trace starts; `RoomPage` first post-frame callback marks `room_local_first_frame` and finishes even when remote sync has not completed. At route pop (`Navigator.push` future resolves), a separate `room_local_frame`/`leave` trace marks `route_exit_requested`; after `route.completed` and one post-frame callback it marks `route_exit_frame` and finishes. Failed push, replaced route, revoke, or account teardown cancels the matching trace once, never records a successful visible frame. Keep the existing `conversation_open` operation ID and remote-wait result unchanged. Tests must cover repeated enter/leave without active trace accumulation and navigation while receiving sync events.

```dart
test('local entry frame is independent of remote sync', () {
  final records = <PerformanceRecord>[];
  final recorder = PerformanceTraceRecorder(
    metrics: PerformanceMetrics(enabled: true),
    clockUs: () => 1000,
    onRecord: records.add,
  );
  final probe = RoomRouteFrameProbe(recorder);
  probe.beginEnter();
  probe.onRoomFirstFrame();
  expect(records.single.operation, PerformanceOperationType.roomLocalFrame);
  expect(records.single.roomRoutePhase, RoomRoutePhase.enter);
  expect(records.single.stagesUs.keys.last, PerformanceStage.roomLocalFirstFrame);
});
```

- [ ] **Step 2: Verify RED.** Run `flutter test --no-pub test/features/matrix/room_route_frame_probe_test.dart test/features/matrix/room_open_performance_trace_test.dart test/features/matrix/room_page_anchor_navigation_test.dart`; expect only new assertions to fail.

- [ ] **Step 3: Add minimal route producer.** In `_openManagedRoomRoute` at `app_home.dart:2355–2505` start the entry probe immediately before `navigator.push(route)` and pass it to `RoomPage`. Use its existing first post-frame callback at `room_page.dart:932` to finish local entry. After `await visible`, mark leave request; after `await route.completed`, schedule one post-frame callback and finish leave, with a 1200 ms cancel deadline for a missing frame. In `catch/finally`, cancel both probes and do not keep `route`, `roomId`, `BuildContext`, or `RoomPage` in any global diagnostic buffer. Never wait for remote Matrix sync before reporting the local first frame. The probe records only direction, timing, closed result, and frames; the existing route/lease fix remains owned by the room agent.

- [ ] **Step 4: Add minimal keyboard hook.** In `RoomPage` attach the helper to `inputFocusNode` and `WidgetsBindingObserver.didChangeMetrics`; call `request(show)` on text-field tap/focus gain, and `request(hide)` before `unfocus` in `_dismissComposerExtensions`, `_togglePanel`, `_toggleVoice`, and route exit. Read `View.of(context).viewInsets.bottom / devicePixelRatio` only when mounted and current. Do not call `setState`, await a request, or read user input from the metric callback. Dispose the helper and remove the focus listener before disposing `inputFocusNode`. The existing composer tap contract remains unchanged.

- [ ] **Step 5: Verify and commit.** Run `flutter test --no-pub test/features/matrix/room_route_frame_probe_test.dart test/features/matrix/room_keyboard_transition_probe_test.dart test/features/matrix/room_open_performance_trace_test.dart test/features/matrix/room_page_anchor_navigation_test.dart test/ui/chat_composer_bar_test.dart test/ui/composer_metrics_test.dart`. Expect no extra frame operations on idle builds, exactly one final operation per real transition, no leaked trace after route pop, and existing composer/navigation tests green. Commit the helper, hooks, and tests only after the room/search agents' patches are integrated.

## Task 3: Sync burst count through existing public Matrix stream

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_sync_watchdog.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_sync_phase_metrics.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/matrix_sync_watchdog_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/matrix_sync_phase_metrics_test.dart`

- [ ] **Step 1: Write RED tests.** The public SDK `Client.onSync` fires after `_handleSync` and before `cleaningUp`/`finished` (`apps/mobile_flutter/third_party/matrix/lib/src/client.dart:2451`). Count `joined` and `left` room `timeline?.events?.length` once per active sync cycle, clamp at 100000, and attach as `timeline_event_count` to the existing `matrix_sync` final trace. Empty sync yields zero. An out-of-cycle or late update is ignored, failed sync retains only a count that was observed in that cycle, and a new waiting status resets it. Do not inspect event bodies, room IDs, sender IDs, or decrypted text. Count raw timeline envelopes; never label this as confirmed user-message count.

```dart
test('sync trace carries only a bounded timeline envelope count', () {
  final metrics = MatrixSyncPhaseMetrics(traceRecorder: recorder);
  metrics.record(SyncStatus.waitingForResponse);
  metrics.record(SyncStatus.processing);
  metrics.recordTimelineEventCount(50);
  metrics.record(SyncStatus.cleaningUp);
  metrics.record(SyncStatus.finished);
  expect(records.single.timelineEventCount, 50);
});
```

- [ ] **Step 2: Verify RED.** Run `flutter test --no-pub test/features/matrix/matrix_sync_phase_metrics_test.dart test/features/matrix/matrix_sync_watchdog_test.dart`; expect the new count path to fail.

- [ ] **Step 3: Implement on the public stream.** Extend `MatrixSyncWatchdogTarget` with `Stream<int> get timelineEventCounts`; the real adapter maps `Client.onSync.stream` to the sum of joined/left timeline list lengths, capped at 100000 without materializing another list. Subscribe alongside `syncStatus`; deliver counts to `MatrixSyncPhaseMetrics.recordTimelineEventCount` only after `processing` and before `finished`. Cancel both subscriptions on watchdog dispose. `MatrixSyncPhaseMetrics` writes the count to its current `PerformanceTrace.timelineEventCount`, preserving the already instrumented `syncResponseReceived`, `syncProcessingDone`, and `syncCleanupDone` stages. Do not modify `third_party/matrix` for this metric.

```dart
int countTimelineEnvelopes(SyncUpdate update) {
  var count = 0;
  for (final room in update.rooms?.join?.values ?? const <JoinedRoomUpdate>[]) {
    count = (count + (room.timeline?.events?.length ?? 0)).clamp(0, 100000);
  }
  for (final room in update.rooms?.leave?.values ?? const <LeftRoomUpdate>[]) {
    count = (count + (room.timeline?.events?.length ?? 0)).clamp(0, 100000);
  }
  return count;
}
```

- [ ] **Step 4: Verify GREEN and commit.** Run `flutter test --no-pub test/features/matrix/matrix_sync_phase_metrics_test.dart test/features/matrix/matrix_sync_watchdog_test.dart test/performance/performance_trace_upload_test.dart`; expect phase order, count bound, and no-content serialization tests green. Commit these four files as `feat(diagnostics): count sync timeline envelopes`.

## Task 4: Fragment-write aggregate handoff and end-to-end evidence

**Files:**
- Modify only after SDK owner handoff: `apps/mobile_flutter/lib/features/matrix/matrix_sync_phase_metrics.dart`
- Modify only after SDK owner handoff: `apps/mobile_flutter/test/features/matrix/matrix_sync_phase_metrics_test.dart`
- Modify: `docs/verification/2026-09-28-account-diagnostics-correlation.md`

- [ ] **Step 1: Bind a reviewed SDK aggregate, if exposed by the batch-write patch.** The SDK owner may expose one public, content-free callback per sync transaction: fragment write count and summed/maximum elapsed microseconds. Write a RED test where 50 incoming events touching one fragment report one aggregate write, not 50 per-event records. The callback carries no room/fragment/event IDs. Add fixed `fragment_write_started` and `fragment_write_done` stages or bounded aggregate counters through the account diagnostic receiver/client contract before emitting them. If the SDK patch exposes no safe aggregate, record `fragment_metric_unavailable` in verification and rely on existing `sync_processing` timing; do not introduce a broad database rewrite solely for telemetry.

- [ ] **Step 2: Run focused and integration gates.** Run the Task 1–3 Flutter tests, `flutter analyze --no-pub`, and the account diagnostic wire/spool tests. Verify a synthetic 50-event burst produces one `matrix_sync` record with count and processing duration, while 50 keyboard show/hide events cannot grow the spool beyond its existing cap. Use the same local dataset for 2190 versus candidate frame/CPU comparison. Run `pwsh -NoProfile -File scripts/verify.ps1` after its environment preflight when changed inputs require it; reuse an equivalent completed gate only under the mobile delivery runbook's hash rules. Record actual Android simulator measurements separately from Redmi K80 pending measurements. No production rollout claim follows from a simulator test.

- [ ] **Step 3: Review and commit evidence.** Perform specification-compliance review first, then quality/security review. Confirm all three producers send closed enums/counts only, no new keyboard-time HTTP, no room IDs/content/credentials, and proper observer/subscription cleanup. Record 2190 frozen hashes, RED/GREEN test results, 422 compatibility, diagnostic loss, server log coverage, and uncertainty classification. Commit the evidence document after tests pass; client release follows the normal Android packaging and signing workflow, while service publication requires separate approval.
