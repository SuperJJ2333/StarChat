import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/outbox/media_outbox_recovery_service.dart';
import '../../core/outbox/media_outbox_store.dart';
import 'room_timeline_controller.dart';

/// Route-owned projection only. The account service retains all transport and
/// durable-source ownership when this projection is disposed.
final class MediaOutboxTimeline extends ChangeNotifier {
  MediaOutboxTimeline(
      {required this.service,
      required this.roomId,
      required this.controller,
      required this.isCurrent}) {
    service.addListener(reload);
    unawaited(reload());
  }

  final MediaOutboxRecoveryService service;
  final String roomId;
  final RoomTimelineController controller;
  final bool Function() isCurrent;
  Map<String, MediaOutboxTask> tasks = const {};
  Object? error;
  bool _disposed = false;
  int _revision = 0;
  bool get current => !_disposed && service.active && isCurrent();

  Future<void> reload() async {
    final revision = ++_revision;
    if (!current) {
      if (!_disposed) {
        tasks = const {};
        controller.clearMediaProjection();
        notifyListeners();
      }
      return;
    }
    try {
      final pending = await service.store.pending();
      if (!current || revision != _revision) return;
      final next = {
        for (final task in pending)
          if (task.roomId == roomId) task.txid: task
      };
      // Observe terminal transitions of rows this route already owns. Do not
      // resurrect old sent rows after local history has been cleared.
      for (final entry in tasks.entries) {
        final id = entry.key;
        if (next.containsKey(id)) continue;
        if (entry.value.terminal) {
          if (entry.value.stage == MediaOutboxStage.sent &&
              !controller.hasConfirmedMediaEcho(entry.value)) {
            next[id] = entry.value;
          }
          continue;
        }
        final task = await service.store.byTxid(id);
        if (!current || revision != _revision) return;
        if (task != null) next[id] = task;
      }
      tasks = next;
      error = null;
      controller.projectMediaTasks(next.values);
      notifyListeners();
    } catch (failure) {
      if (!current || revision != _revision) return;
      // Keep the previous actionable rows if storage becomes unavailable.
      error = failure;
      notifyListeners();
    }
  }

  Future<void> retry(String txid) async {
    if (!current) return;
    final task = tasks[txid];
    if (task == null || task.terminal) return;
    try {
      await service.dispatch(task, userRetry: true);
    } finally {
      await reload();
    }
  }

  Future<void> cancel(String txid) async {
    if (!current) return;
    await service.cancel(txid);
    await reload();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    service.removeListener(reload);
    super.dispose();
  }
}
