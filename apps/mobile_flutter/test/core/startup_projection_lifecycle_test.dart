import 'dart:convert';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';
import 'package:matrix/matrix.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_coordinator.dart';

class _EchoClient extends Client {
  _EchoClient() : super('synthetic-echo');
  String? testDevice;
  @override
  String? get deviceID => testDevice;
}

void main() {
  test(
      'provisional echo listener accepts restored identity and rejects wrong or stale identity',
      () async {
    final client = _EchoClient();
    final full = Completer<void>();
    client.seedStartupRooms([], full.future);
    final epoch = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        startupProjection: StartupProjection([]),
        startupAdmission: StartupProjectionAdmission(
            scope: '',
            homeserver: 'https://synthetic.test',
            userId: '@synthetic:test',
            deviceId: 'DEVICE',
            fingerprint: 'synthetic',
            databaseGeneration: 'synthetic',
            installationId: epoch,
            epoch: epoch,
            databaseKey: base64Url.encode(List.filled(32, 2)),
            registrationKey: 'synthetic'));
    Future<void> queue(String id) async {
      await owner.outgoingWork.enqueue(MatrixOutgoingWorkJob(id: id, items: [
        MatrixOutgoingWorkItem(
            id: id,
            targetRoomId: '!synthetic:test',
            txid: id,
            send: (_) async => r'$echo')
      ]));
      await owner.outgoingWork.drain();
    }

    Future<void> echo(String id) async {
      client.onEvent.add(EventUpdate(
          roomID: '!synthetic:test',
          type: EventUpdateType.timeline,
          content: {
            'type': EventTypes.Encrypted,
            'event_id': r'$echo',
            'sender': '@synthetic:test',
            'unsigned': {'transaction_id': id}
          }));
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await queue('first');
      client.setUserId('@synthetic:test');
      client.testDevice = 'WRONG';
      full.complete();
      await client.initializationCompleted;
      await echo('first');
      expect(owner.outgoingWork.itemsForRoom('!synthetic:test'), hasLength(1));
      client.testDevice = 'DEVICE';
      await echo('first');
      expect(owner.outgoingWork.itemsForRoom('!synthetic:test'), isEmpty);
      await queue('second');
      client.setUserId('@other:test');
      await echo('second');
      expect(owner.outgoingWork.itemsForRoom('!synthetic:test'), hasLength(1));
    } finally {
      owner.outgoingWork.dispose();
      await client.dispose();
    }
  });
  test(
      'disposing provisional SDK owner cancels held background and full readiness',
      () async {
    final client = Client('synthetic-disposal');
    final never = Completer<void>();
    client.seedStartupRooms([], never.future);
    final full = expectLater(client.initializationCompleted, throwsStateError);
    final resume =
        expectLater(client.awaitStartupResume(never.future), throwsStateError);
    await client.dispose();
    await Future.wait([full, resume]);
  });
  test('new epoch cannot capture old display while mutation apply is held',
      () async {
    var invalidations = 0;
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      invalidations++;
    })
      ..markVerified();
    final before = owner.beginCapture()!;
    final mutation = owner.beginMutation('hide');
    await mutation.beforeApply;
    expect(invalidations, 1);
    expect(owner.isCurrent(before), isFalse);
    expect(owner.beginCapture(), isNull,
        reason: 'durable new epoch must not admit a snapshot of pre-apply UI');
    mutation.finish(applied: true);
    expect(owner.beginCapture(), isNotNull);
  });

  test('mutation during head commit invalidates before apply can start',
      () async {
    final writing = Completer<void>();
    final release = Completer<void>();
    var invalidations = 0;
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      invalidations++;
    })
      ..markVerified();
    final commit = owner.commit(owner.beginCapture()!, () async {
      writing.complete();
      await release.future;
    });
    await writing.future;
    final mutation = owner.beginMutation('clear');
    var applyAllowed = false;
    final before = mutation.beforeApply.then((_) => applyAllowed = true);
    await Future<void>.delayed(Duration.zero);
    expect(applyAllowed, isFalse);
    release.complete();
    expect(await commit, isFalse);
    await before;
    expect(invalidations, greaterThanOrEqualTo(1));
    mutation.finish(applied: true);
  });

  test('nested tickets, failed apply and retired owner cannot prime', () async {
    final owner = StartupProjectionCoordinator(invalidateHead: () async {})
      ..markVerified();
    final a = owner.beginMutation('outer');
    final b = owner.beginMutation('inner');
    await Future.wait([a.beforeApply, b.beforeApply]);
    a.finish(applied: true);
    a.finish(applied: true);
    expect(owner.beginCapture(), isNull);
    b.finish(applied: false);
    owner.markVerified();
    expect(owner.beginCapture(), isNull);
    final fresh = StartupProjectionCoordinator(invalidateHead: () async {})
      ..markVerified();
    owner.retire();
    b.finish(applied: true);
    expect(fresh.beginCapture(), isNotNull);
  });

  test('failed invalidation prevents apply and poisons this owner', () async {
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      throw StateError('synthetic locked store');
    })
      ..markVerified();
    var applied = false;
    await expectLater(
        owner.runMutation('clear', () async {
          applied = true;
        }),
        throwsStateError);
    expect(applied, isFalse);
    expect(owner.beginCapture(), isNull);
  });
}
