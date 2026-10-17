import 'dart:convert';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';
import 'package:matrix/matrix.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_coordinator.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;
import '../features/matrix/matrix_client_factory_test.dart'
    show LogoutTrackingClient;

class _EchoClient extends Client {
  _EchoClient() : super('synthetic-echo');
  String? testDevice;
  @override
  String? get deviceID => testDevice;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test('pending unadmitted room cannot queue with only restored credentials',
      () async {
    final client = _EchoClient()..setUserId('@synthetic:test');
    final room = Room(
        id: '!synthetic:test', client: client, membership: Membership.join);
    client.rooms.add(room);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'));
    final lease = await owner.openRoomLease(room.id);
    final full = Completer<void>();
    client.seedStartupRooms([room], full.future);
    try {
      expect(lease.canQueueLocalText, isFalse);
      client.accessToken = 'synthetic-token';
      expect(client.isLogged(), isTrue);
      expect(client.encryptionEnabled, isFalse);
      expect(lease.canQueueLocalText, isFalse,
          reason:
              'credentials alone do not prove canonical local SDK recovery');
    } finally {
      full.complete();
      await lease.cancel();
      owner.outgoingWork.dispose();
      await client.dispose();
    }
  });
  test('local queue permission is independent of crypto transport readiness',
      () async {
    final client = LogoutTrackingClient('queue',
        loggedIn: true,
        matrixUserId: '@synthetic:test',
        matrixDeviceId: 'DEVICE');
    final room = Room(
        id: '!synthetic:test', client: client, membership: Membership.join);
    client.roomOverride = room;
    room.setState(Event(
        room: room,
        eventId: 'synthetic-state',
        senderId: '@synthetic:test',
        originServerTs: DateTime.utc(2026),
        type: EventTypes.Encryption,
        stateKey: '',
        content: {'algorithm': AlgorithmTypes.megolmV1AesSha2}));
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'synthetic',
                databaseGeneration: 'synthetic'),
        suspendClient: (_) async {});
    final lease = await owner.openRoomLease(room.id);
    try {
      expect(client.encryptionEnabled, isFalse);
      expect(lease.canQueueLocalText, isTrue,
          reason: 'durable admission does not require encryption transport');
      room.membership = Membership.leave;
      expect(lease.canQueueLocalText, isFalse);
      room.membership = Membership.join;
      room.setState(Event(
          room: room,
          eventId: 'synthetic-state',
          senderId: '@synthetic:test',
          originServerTs: DateTime.utc(2026),
          type: EventTypes.RoomPowerLevels,
          stateKey: '',
          content: {
            'events': {EventTypes.Encrypted: 100}
          }));
      expect(lease.canQueueLocalText, isFalse);
      room.setState(Event(
          room: room,
          eventId: 'synthetic-state',
          senderId: '@synthetic:test',
          originServerTs: DateTime.utc(2026),
          type: EventTypes.RoomPowerLevels,
          stateKey: '',
          content: {
            'events': {EventTypes.Encrypted: 0}
          }));
      expect(lease.canQueueLocalText, isTrue);
      client.roomOverride =
          Room(id: room.id, client: client, membership: Membership.join);
      expect(lease.canQueueLocalText, isFalse,
          reason: 'a replaced canonical Room cannot authorize an old lease');
      client.roomOverride = room;
      expect(lease.canQueueLocalText, isTrue);
      await lease.cancel();
      expect(lease.canQueueLocalText, isFalse);
      final another = await owner.openRoomLease(room.id);
      final suspension = owner.suspend();
      expect(another.canQueueLocalText, isFalse,
          reason: 'owner revocation denies queue admission synchronously');
      await suspension;
    } finally {
      owner.outgoingWork.dispose();
      await client.dispose();
    }
  });
  test('revoked preinit projection cannot use seeded default send power',
      () async {
    final client = _EchoClient()..setUserId('@synthetic:test');
    client.testDevice = 'DEVICE';
    final room = Room(
        id: '!synthetic:test', client: client, membership: Membership.join);
    final full = Completer<void>();
    client.seedStartupRooms([room], full.future);
    final secure = SecureSessionStore(MemorySecureKeyValueStore());
    final epoch = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        secureSessionStore: secure,
        startupProjection: StartupProjection([
          StartupProjectionRoom(
              id: room.id,
              name: 'Synthetic',
              direct: false,
              peer: null,
              unread: 0,
              pinned: false,
              muted: false,
              canSend: true,
              activity: 0,
              events: [])
        ]),
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
    final lease = await owner.openRoomLease(room.id);
    try {
      expect(lease.canQueueLocalText, isTrue);
      final mutation = secure.startupProjectionCoordinator!
          .beginMutation('synthetic-revoke');
      await mutation.beforeApply;
      mutation.finish(applied: true);
      expect(client.isInitializationPending, isTrue);
      expect(lease.canQueueLocalText, isFalse,
          reason:
              'invalid preinit display cannot fall through to seeded room power');
      full.complete();
      await client.initializationCompleted;
      expect(lease.canQueueLocalText, isTrue);
    } finally {
      if (!full.isCompleted) full.complete();
      await lease.cancel();
      owner.outgoingWork.dispose();
      await client.dispose();
    }
  });
  test('same identity resume cannot revive the original admitted room head',
      () async {
    final first = LogoutTrackingClient('first',
        loggedIn: true,
        matrixUserId: '@synthetic:test',
        matrixDeviceId: 'DEVICE');
    final resumed = LogoutTrackingClient('resumed',
        loggedIn: true,
        matrixUserId: '@synthetic:test',
        matrixDeviceId: 'DEVICE');
    for (final client in [first, resumed]) {
      client.roomOverride = Room(
          id: '!synthetic:test', client: client, membership: Membership.join);
    }
    final secure = SecureSessionStore(MemorySecureKeyValueStore());
    final epoch = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
    final owner = MatrixSdkE2eeClient(first,
        homeserver: Uri.parse('https://synthetic.test'),
        secureSessionStore: secure,
        suspendClient: (_) async {},
        resumeClient: () async => resumed,
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: true,
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'synthetic',
                databaseGeneration: 'synthetic'),
        startupProjection: StartupProjection([
          StartupProjectionRoom(
              id: '!synthetic:test',
              name: 'Synthetic',
              direct: false,
              peer: null,
              unread: 0,
              pinned: false,
              muted: false,
              canSend: true,
              activity: 0,
              events: [])
        ]),
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
    try {
      expect(owner.hasCachedRoomDisplay('!synthetic:test'), isTrue);
      final mutation =
          secure.startupProjectionCoordinator!.beginMutation('synthetic-edit');
      await mutation.beforeApply;
      mutation.finish(applied: true);
      expect(owner.hasCachedRoomDisplay('!synthetic:test'), isFalse);
      await owner.suspend();
      await owner.sync();
      final lease = await owner.openRoomLease('!synthetic:test');
      expect(lease.roomInfo.id, '!synthetic:test');
      expect(owner.hasCachedRoomDisplay('!synthetic:test'), isFalse,
          reason:
              'new coordinator must not re-admit the retired original head');
      expect(
          secure.startupProjectionCoordinator!.beginDisplayCapture(), isNotNull,
          reason:
              'same-owner canonical heads may still acquire fresh display permits');
      await lease.cancel();
    } finally {
      owner.outgoingWork.dispose();
      await first.dispose();
      await resumed.dispose();
    }
  });
  test(
      'offline display permits never grant disk capture and retire on mutation',
      () async {
    final owner = StartupProjectionCoordinator(invalidateHead: () async {});
    final display = owner.beginDisplayCapture()!;
    expect(owner.beginCapture(), isNull);
    expect(owner.isDisplayCurrent(display), isTrue);
    final mutation = owner.beginMutation('privacy');
    await mutation.beforeApply;
    expect(owner.isDisplayCurrent(display), isFalse);
    expect(owner.beginDisplayCapture(), isNull);
    mutation.finish(applied: true);
    final fresh = owner.beginDisplayCapture()!;
    expect(owner.displayRevoked, isTrue);
    expect(owner.isDisplayCurrent(display), isFalse);
    expect(owner.isDisplayCurrent(fresh), isTrue);
    expect(owner.beginCapture(), isNull);
    owner.markVerified();
    expect(owner.beginCapture(), isNotNull);
    owner.retire();
    expect(owner.isDisplayCurrent(fresh), isFalse);
  });
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
