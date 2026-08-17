import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/message_reminder_service.dart';

final class FakeReminderBackend implements MessageReminderBackend {
  final sent = <MessageReminder>[];

  @override
  Future<void> sendEncrypted(MessageReminder reminder) async =>
      sent.add(reminder);
}

final class FakeNotificationScheduler implements LocalNotificationScheduler {
  final scheduled = <MessageReminder>[];
  final cancelled = <String>[];
  final overdue = <String>[];

  @override
  Future<void> schedule(MessageReminder reminder) async =>
      scheduled.add(reminder);

  @override
  Future<void> cancel(String id) async => cancelled.add(id);

  @override
  Future<void> showOverdue(String id) async => overdue.add(id);
}

final class FakeReminderSnapshotSource implements ReminderSnapshotSource {
  final changesController = StreamController<void>.broadcast();
  List<MessageReminder> reminders = const [];

  @override
  Stream<void> get changes => changesController.stream;

  @override
  Future<List<MessageReminder>> load() async => reminders;
}

void main() {
  final now = DateTime.utc(2026, 8, 17, 12);

  test('schedule syncs encrypted definition and creates a generic local alert',
      () async {
    final backend = FakeReminderBackend();
    final scheduler = FakeNotificationScheduler();
    final service = MessageReminderService(
      backend: backend,
      scheduler: scheduler,
      now: () => now,
    );

    final reminder = await service.create(
      roomId: '!chat:test',
      eventId: r'$event',
      dueAt: now.add(const Duration(hours: 1)),
    );

    expect(backend.sent.single, reminder);
    expect(scheduler.scheduled.single, reminder);
    expect(reminder.toJson(), isNot(contains('body')));
  });

  test('incoming reminders are idempotent and overdue sync is surfaced once',
      () async {
    final scheduler = FakeNotificationScheduler();
    final service = MessageReminderService(
      backend: FakeReminderBackend(),
      scheduler: scheduler,
      now: () => now,
    );
    final reminder = MessageReminder(
      id: 'same-id',
      roomId: '!chat:test',
      eventId: r'$event',
      dueAt: now.subtract(const Duration(minutes: 1)),
      status: MessageReminderStatus.scheduled,
      updatedAt: now.subtract(const Duration(hours: 1)),
    );

    await service.applyIncoming([reminder, reminder]);

    expect(scheduler.overdue, ['same-id']);
  });

  test('cancel syncs state and removes the local notification', () async {
    final backend = FakeReminderBackend();
    final scheduler = FakeNotificationScheduler();
    final service = MessageReminderService(
      backend: backend,
      scheduler: scheduler,
      now: () => now,
    );
    final reminder = await service.create(
      roomId: '!chat:test',
      eventId: r'$event',
      dueAt: now.add(const Duration(hours: 1)),
    );

    await service.cancel(reminder);

    expect(backend.sent.last.status, MessageReminderStatus.cancelled);
    expect(scheduler.cancelled, [reminder.id]);
  });

  test('reminder JSON round-trips without message plaintext', () {
    final reminder = MessageReminder(
      id: 'reminder',
      roomId: '!chat:test',
      eventId: r'$event',
      dueAt: now.add(const Duration(hours: 1)),
      status: MessageReminderStatus.scheduled,
      updatedAt: now,
    );

    expect(MessageReminder.fromJson(reminder.toJson()).toJson(),
        reminder.toJson());
  });

  test('sync coordinator continuously applies remote reminder changes',
      () async {
    final scheduler = FakeNotificationScheduler();
    final service = MessageReminderService(
      backend: FakeReminderBackend(),
      scheduler: scheduler,
      now: () => now,
    );
    final source = FakeReminderSnapshotSource();
    final scheduled = MessageReminder(
      id: 'remote-reminder',
      roomId: '!chat:test',
      eventId: r'$event',
      dueAt: now.add(const Duration(hours: 1)),
      status: MessageReminderStatus.scheduled,
      updatedAt: now,
    );
    source.reminders = [scheduled];
    final coordinator = MessageReminderSyncCoordinator(
      source: source,
      service: service,
    );

    await coordinator.start();
    expect(scheduler.scheduled, [scheduled]);

    source.reminders = [
      scheduled.copyWith(
        status: MessageReminderStatus.cancelled,
        updatedAt: now.add(const Duration(minutes: 1)),
      ),
    ];
    source.changesController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(scheduler.cancelled, ['remote-reminder']);
    await coordinator.dispose();
    await source.changesController.close();
  });

  test('sync bootstrap retries after an offline initialization failure',
      () async {
    final retries = StreamController<void>.broadcast();
    final source = FakeReminderSnapshotSource();
    final service = MessageReminderService(
      backend: FakeReminderBackend(),
      scheduler: FakeNotificationScheduler(),
      now: () => now,
    );
    var attempts = 0;
    final bootstrap = MessageReminderSyncBootstrapper(
      retries: retries.stream,
      create: () async {
        attempts += 1;
        if (attempts == 1) throw StateError('offline');
        return MessageReminderSyncCoordinator(
          source: source,
          service: service,
        );
      },
    );

    await bootstrap.start();
    expect(bootstrap.active, isFalse);

    retries.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(bootstrap.active, isTrue);
    expect(attempts, 2);
    await bootstrap.dispose();
    await source.changesController.close();
    await retries.close();
  });
}
