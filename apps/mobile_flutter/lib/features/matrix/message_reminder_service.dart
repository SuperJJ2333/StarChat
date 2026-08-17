import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

enum MessageReminderStatus { scheduled, cancelled, completed }

final class MessageReminder {
  const MessageReminder({
    required this.id,
    required this.roomId,
    required this.eventId,
    required this.dueAt,
    required this.status,
    required this.updatedAt,
  });

  final String id;
  final String roomId;
  final String eventId;
  final DateTime dueAt;
  final MessageReminderStatus status;
  final DateTime updatedAt;

  factory MessageReminder.fromJson(Map<String, Object?> json) =>
      MessageReminder(
        id: json['id']! as String,
        roomId: json['room_id']! as String,
        eventId: json['event_id']! as String,
        dueAt: DateTime.parse(json['due_at']! as String).toUtc(),
        status: MessageReminderStatus.values.byName(json['status']! as String),
        updatedAt: DateTime.parse(json['updated_at']! as String).toUtc(),
      );

  MessageReminder copyWith({
    MessageReminderStatus? status,
    DateTime? updatedAt,
  }) =>
      MessageReminder(
        id: id,
        roomId: roomId,
        eventId: eventId,
        dueAt: dueAt,
        status: status ?? this.status,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'room_id': roomId,
        'event_id': eventId,
        'due_at': dueAt.toUtc().toIso8601String(),
        'status': status.name,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}

abstract interface class MessageReminderBackend {
  Future<void> sendEncrypted(MessageReminder reminder);
}

abstract interface class LocalNotificationScheduler {
  Future<void> schedule(MessageReminder reminder);
  Future<void> cancel(String id);
  Future<void> showOverdue(String id);
}

abstract interface class ReminderSnapshotSource {
  Stream<void> get changes;
  Future<List<MessageReminder>> load();
}

final class MessageReminderService {
  MessageReminderService({
    required this.backend,
    required this.scheduler,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final MessageReminderBackend backend;
  final LocalNotificationScheduler scheduler;
  final DateTime Function() now;
  final Map<String, MessageReminder> _known = {};
  final Set<String> _overdueShown = {};

  Future<MessageReminder> create({
    required String roomId,
    required String eventId,
    required DateTime dueAt,
  }) async {
    final updatedAt = now().toUtc();
    if (!dueAt.isAfter(updatedAt)) {
      throw ArgumentError.value(dueAt, 'dueAt', '提醒时间必须在未来');
    }
    final id = sha256
        .convert(utf8.encode(
          '$roomId\u0000$eventId\u0000${dueAt.toUtc().toIso8601String()}',
        ))
        .toString()
        .substring(0, 32);
    final reminder = MessageReminder(
      id: id,
      roomId: roomId,
      eventId: eventId,
      dueAt: dueAt.toUtc(),
      status: MessageReminderStatus.scheduled,
      updatedAt: updatedAt,
    );
    await backend.sendEncrypted(reminder);
    _known[id] = reminder;
    await scheduler.schedule(reminder);
    return reminder;
  }

  Future<void> cancel(MessageReminder reminder) async {
    final cancelled = reminder.copyWith(
      status: MessageReminderStatus.cancelled,
      updatedAt: now().toUtc(),
    );
    await backend.sendEncrypted(cancelled);
    _known[reminder.id] = cancelled;
    await scheduler.cancel(reminder.id);
  }

  Future<void> applyIncoming(Iterable<MessageReminder> incoming) async {
    for (final reminder in incoming) {
      final current = _known[reminder.id];
      if (current != null && !reminder.updatedAt.isAfter(current.updatedAt)) {
        continue;
      }
      _known[reminder.id] = reminder;
      if (reminder.status != MessageReminderStatus.scheduled) {
        await scheduler.cancel(reminder.id);
      } else if (reminder.dueAt.isAfter(now().toUtc())) {
        await scheduler.schedule(reminder);
      } else if (_overdueShown.add(reminder.id)) {
        await scheduler.showOverdue(reminder.id);
      }
    }
  }
}

final class MessageReminderSyncCoordinator {
  MessageReminderSyncCoordinator({required this.source, required this.service});

  final ReminderSnapshotSource source;
  final MessageReminderService service;
  StreamSubscription<void>? _subscription;
  bool _refreshing = false;
  bool _refreshPending = false;

  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = source.changes.listen((_) {
      unawaited(_refreshAfterSync());
    });
    try {
      await refresh();
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
  }

  Future<void> _refreshAfterSync() async {
    try {
      await refresh();
    } catch (_) {
      // A later Matrix sync retries without interrupting the app session.
    }
  }

  Future<void> refresh() async {
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshPending = false;
        await service.applyIncoming(await source.load());
      } while (_refreshPending);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

final class MessageReminderSyncBootstrapper {
  MessageReminderSyncBootstrapper({
    required this.retries,
    required this.create,
    this.onReady,
  });

  final Stream<void> retries;
  final Future<MessageReminderSyncCoordinator> Function() create;
  final void Function(MessageReminderSyncCoordinator coordinator)? onReady;
  StreamSubscription<void>? _retrySubscription;
  MessageReminderSyncCoordinator? _coordinator;
  bool _starting = false;
  bool _retryPending = false;
  bool _disposed = false;

  bool get active => _coordinator != null;

  Future<void> start() async {
    if (_disposed) return;
    _retrySubscription ??= retries.listen((_) {
      unawaited(_tryStart());
    });
    await _tryStart();
  }

  Future<void> _tryStart() async {
    if (active) return;
    if (_starting) {
      _retryPending = true;
      return;
    }
    _starting = true;
    MessageReminderSyncCoordinator? candidate;
    try {
      candidate = await create();
      await candidate.start();
      if (_disposed) {
        await candidate.dispose();
        return;
      }
      _coordinator = candidate;
      await _retrySubscription?.cancel();
      _retrySubscription = null;
      onReady?.call(candidate);
    } catch (_) {
      await candidate?.dispose();
    } finally {
      _starting = false;
      if (_retryPending && !active) {
        _retryPending = false;
        unawaited(_tryStart());
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _retrySubscription?.cancel();
    _retrySubscription = null;
    await _coordinator?.dispose();
    _coordinator = null;
  }
}
