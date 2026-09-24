import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:matrix/matrix.dart';
import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async {
      final root = Directory(
          '../../docs/verification/artifacts/2026-09-12/media-interactions/d4-account-client');
      await root.create(recursive: true);
      return root.path;
    },
  );

  MatrixOutgoingWorkJob echoJob({
    required String id,
    required String roomId,
    required String txid,
    required Future<String> Function(MatrixOutgoingWorkAttempt attempt) send,
  }) =>
      MatrixOutgoingWorkJob(
        id: id,
        source: MatrixOutgoingWorkSource(id: '$id-source', retainedBytes: 1),
        items: [
          MatrixOutgoingWorkItem(
            id: '$id-item',
            targetRoomId: roomId,
            txid: txid,
            send: send,
          ),
        ],
      );

  EventUpdate syncedOwnMessage({
    required String roomId,
    required String senderId,
    required String eventId,
    String? transactionId,
    EventUpdateType updateType = EventUpdateType.timeline,
    String eventType = EventTypes.Message,
    int? localStatus,
  }) =>
      EventUpdate(
        roomID: roomId,
        type: updateType,
        content: {
          'type': eventType,
          'event_id': eventId,
          'sender': senderId,
          if (transactionId != null || localStatus != null)
            'unsigned': {
              if (transactionId != null) 'transaction_id': transactionId,
              if (localStatus != null) messageSendingStatusKey: localStatus,
            },
        },
      );

  test(
      'account event echo frees an unopened target and joins an early event id',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final matrix = MatrixSdkE2eeClient(
      a,
      homeserver: Uri.parse('https://matrix.example'),
      outgoingWorkFactory: (accountId) => MatrixOutgoingWorkCoordinator(
        accountId: accountId,
        maxOutstandingItems: 1,
      ),
      readContinuityMetadata: (client) async => MatrixClientContinuityMetadata(
        isLoggedIn: client.isLogged(),
        userId: client.userID,
        deviceId: client.deviceID,
        ed25519Fingerprint: 'key-${client.userID}',
        databaseGeneration: 'db-${client.userID}',
      ),
    );
    await matrix.outgoingWork.enqueue(echoJob(
      id: 'unopened-target',
      roomId: '!unopened:test',
      txid: 'outgoing-unopened',
      send: (_) async => r'$unopened-echo',
    ));
    await matrix.outgoingWork.drain();
    expect(matrix.outgoingWork.itemsForRoom('!unopened:test'), hasLength(1));

    a.onEvent.add(syncedOwnMessage(
      roomId: '!unopened:test',
      senderId: '@a:test',
      eventId: r'$unopened-echo',
      transactionId: 'outgoing-unopened',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(matrix.outgoingWork.itemsForRoom('!unopened:test'), isEmpty,
        reason: 'No target room lease is required for account-owned echo ack.');

    await matrix.outgoingWork.enqueue(echoJob(
      id: 'early-event-only',
      roomId: '!unopened:test',
      txid: 'outgoing-early-event-only',
      send: (_) async {
        a.onEvent.add(syncedOwnMessage(
          roomId: '!unopened:test',
          senderId: '@a:test',
          eventId: r'$early-event-only',
        ));
        await Future<void>.delayed(Duration.zero);
        return r'$early-event-only';
      },
    ));
    await matrix.outgoingWork.drain();
    expect(matrix.outgoingWork.itemsForRoom('!unopened:test'), isEmpty);
  });

  test('only synced encrypted and decrypted timeline facts settle work',
      () async {
    final client = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    await matrix.outgoingWork.enqueue(echoJob(
      id: 'local-row',
      roomId: '!target:test',
      txid: 'outgoing-local-row',
      send: (_) async => r'$local-row',
    ));
    await matrix.outgoingWork.drain();
    client.onEvent.add(syncedOwnMessage(
      roomId: '!target:test',
      senderId: '@a:test',
      eventId: r'$local-row',
      transactionId: 'outgoing-local-row',
      localStatus: EventStatus.sending.intValue,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(matrix.outgoingWork.itemsForRoom('!target:test'), hasLength(1));

    client.onEvent.add(syncedOwnMessage(
      roomId: '!target:test',
      senderId: '@a:test',
      eventId: r'$local-row',
      transactionId: 'outgoing-local-row',
      eventType: EventTypes.Encrypted,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(matrix.outgoingWork.itemsForRoom('!target:test'), isEmpty);

    await matrix.outgoingWork.enqueue(echoJob(
      id: 'decrypted-row',
      roomId: '!target:test',
      txid: 'outgoing-decrypted-row',
      send: (_) async => r'$decrypted-row',
    ));
    await matrix.outgoingWork.drain();
    client.onEvent.add(syncedOwnMessage(
      roomId: '!target:test',
      senderId: '@a:test',
      eventId: r'$decrypted-row',
      transactionId: 'outgoing-decrypted-row',
      updateType: EventUpdateType.decryptedTimelineQueue,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(matrix.outgoingWork.itemsForRoom('!target:test'), isEmpty);
  });

  test('same-client re-login cannot acknowledge a queued microtask', () async {
    final client = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    await matrix.outgoingWork.enqueue(echoJob(
      id: 'same-client-relogin',
      roomId: '!target:test',
      txid: 'outgoing-same-client-relogin',
      send: (_) async => r'$same-client-relogin',
    ));
    await matrix.outgoingWork.drain();
    client.onEvent.add(syncedOwnMessage(
      roomId: '!target:test',
      senderId: '@a:test',
      eventId: r'$same-client-relogin',
      transactionId: 'outgoing-same-client-relogin',
    ));
    client.matrixDeviceId = 'A-relogged';
    await Future<void>.delayed(Duration.zero);

    expect(matrix.outgoingWork.itemsForRoom('!target:test'), hasLength(1));
  });

  test('old client event streams cannot acknowledge the replacement owner',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final b = LogoutTrackingClient('B',
        loggedIn: true, matrixUserId: '@b:test', matrixDeviceId: 'B');
    final matrix = MatrixSdkE2eeClient(
      a,
      homeserver: Uri.parse('https://matrix.example'),
      suspendClient: (_) async {},
      resumeClient: () async => b,
      selectClientAccount: (_, __) async {},
      readContinuityMetadata: (client) async => MatrixClientContinuityMetadata(
        isLoggedIn: client.isLogged(),
        userId: client.userID,
        deviceId: client.deviceID,
        ed25519Fingerprint: 'key-${client.userID}',
        databaseGeneration: 'db-${client.userID}',
      ),
    );
    await matrix.selectAccount('@b:test', Uri.parse('https://matrix.example'));
    await matrix.outgoingWork.enqueue(echoJob(
      id: 'replacement',
      roomId: '!target:test',
      txid: 'outgoing-replacement',
      send: (_) async => r'$replacement-event',
    ));
    await matrix.outgoingWork.drain();

    a.onEvent.add(syncedOwnMessage(
      roomId: '!target:test',
      senderId: '@a:test',
      eventId: r'$replacement-event',
      transactionId: 'outgoing-replacement',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(matrix.outgoingWork.itemsForRoom('!target:test'), hasLength(1));
  });

  test('concurrent selections close each client before opening the next',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final events = <String>[];
    var selected = '@a:test';
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (client) async {
          events.add('close:${client.userID}');
        },
        selectClientAccount: (_, user) async {
          selected = user;
        },
        resumeClient: () async {
          events.add('open:$selected');
          return LogoutTrackingClient(selected,
              loggedIn: true, matrixUserId: selected, matrixDeviceId: selected);
        },
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'key-${client.userID}',
                databaseGeneration: 'db-${client.userID}'));
    await Future.wait([
      matrix.selectAccount('@b:test', Uri.parse('https://matrix.example')),
      matrix.selectAccount('@c:test', Uri.parse('https://matrix.example')),
    ]);
    expect(events,
        ['close:@a:test', 'open:@b:test', 'close:@b:test', 'open:@c:test']);
    expect(matrix.userId, '@c:test');
  });
  test('failed account reopen does not expose previous identity', () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        resumeClient: () async => throw StateError('database unavailable'),
        selectClientAccount: (_, __) async {},
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint',
                databaseGeneration: 'generation'));
    await expectLater(
        matrix.selectAccount('@b:test', Uri.parse('https://matrix.example')),
        throwsStateError);
    expect(matrix.userId, isNull);
    expect(matrix.isLoggedIn, isFalse);
  });
  test('adapter switch suspends old client without invoking destructive clear',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    var suspended = 0;
    var cleared = 0;
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {
          suspended++;
        },
        clearClientData: (_) async {
          cleared++;
        },
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint',
                databaseGeneration: 'generation'));
    // No selector is configured: fail closed, retaining the old encrypted store.
    await expectLater(
        (matrix as dynamic)
            .selectAccount('@b:test', Uri.parse('https://matrix.example')),
        throwsStateError);
    expect(cleared, 0);
    expect(suspended, 0);
  });
  test(
      'adapter selects restored B and revokes old A capabilities without deletion',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final b = LogoutTrackingClient('B',
        loggedIn: true, matrixUserId: '@b:test', matrixDeviceId: 'B');
    var closed = 0;
    var cleared = 0;
    String? selected;
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {
          closed++;
        },
        resumeClient: () async => b,
        selectClientAccount: (home, user) async {
          selected = user;
        },
        clearClientData: (_) async {
          cleared++;
        },
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint-${client.userID}',
                databaseGeneration: 'generation-${client.userID}'));
    await matrix.selectAccount('@b:test', Uri.parse('https://matrix.example'));
    expect(closed, 1);
    expect(cleared, 0);
    expect(selected, '@b:test');
    expect(matrix.userId, '@b:test');
    expect(matrix.deviceId, 'B');
    expect(matrix.credentialsInvalid, isTrue);
    await expectLater(matrix.openRoomLease('!old:test'), throwsStateError);
  });

  test('account switch revokes A outgoing work and creates a B coordinator',
      () async {
    final a = LogoutTrackingClient('A',
        loggedIn: true, matrixUserId: '@a:test', matrixDeviceId: 'A');
    final b = LogoutTrackingClient('B',
        loggedIn: true, matrixUserId: '@b:test', matrixDeviceId: 'B');
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        resumeClient: () async => b,
        selectClientAccount: (_, __) async {},
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint-${client.userID}',
                databaseGeneration: 'generation-${client.userID}'));
    final old = matrix.outgoingWork;
    await old.enqueue(MatrixOutgoingWorkJob(
      id: 'a-pending',
      source: MatrixOutgoingWorkSource(
        id: 'a-image',
        retainedBytes: 1,
        release: () async {},
      ),
      items: [
        MatrixOutgoingWorkItem(
          id: 'target',
          targetRoomId: '!target:test',
          txid: 'outgoing-a-pending-0-0',
          send: (_) async => 'event',
        ),
      ],
    ));

    await matrix.selectAccount('@b:test', Uri.parse('https://matrix.example'));

    expect(old.isActive, isFalse);
    expect(matrix.outgoingWork, isNot(same(old)));
    expect(matrix.outgoingWork.accountId, '@b:test');
  });

  test('first login replaces the anonymous outgoing coordinator', () async {
    final anonymous = LogoutTrackingClient('anonymous');
    final matrix = MatrixSdkE2eeClient(anonymous,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'fingerprint-${client.userID}',
                databaseGeneration: 'generation-${client.userID}'));
    final beforeLogin = matrix.outgoingWork;
    expect(beforeLogin.accountId, isEmpty);

    await matrix.login('@alice:matrix.test', 'secret');

    expect(beforeLogin.isActive, isFalse);
    expect(matrix.outgoingWork, isNot(same(beforeLogin)));
    expect(matrix.outgoingWork.accountId, '@alice:matrix.test');
  });

  test('same identity reauthentication preserves admitted outgoing work',
      () async {
    final client = LogoutTrackingClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final preparation = Completer<void>();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final work = matrix.outgoingWork;
    await work.enqueue(MatrixOutgoingWorkJob(
      id: 'same-identity-pending',
      source: MatrixOutgoingWorkSource(
        id: 'same-identity-source',
        retainedBytes: 1,
        prepare: (_) => preparation.future,
        release: () async {},
      ),
      items: [
        MatrixOutgoingWorkItem(
          id: 'item',
          targetRoomId: '!target:test',
          txid: 'outgoing-same-identity-0-0',
          send: (_) async => 'event',
        ),
      ],
    ));

    await matrix.login('@alice:matrix.test', 'secret');

    expect(matrix.outgoingWork, same(work));
    expect(work.isActive, isTrue);
    preparation.complete();
    await work.drain();
  });

  test('suspend and clear revoke held preparation without getter revival',
      () async {
    Future<MatrixSdkE2eeClient> create() async {
      final client = LogoutTrackingClient('alice',
          loggedIn: true,
          matrixUserId: '@alice:matrix.test',
          matrixDeviceId: 'ALICE');
      return MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.example'),
          suspendClient: (_) async {},
          clearClientData: (_) async {},
          readContinuityMetadata: (active) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: active.isLogged(),
                  userId: active.userID,
                  deviceId: active.deviceID,
                  ed25519Fingerprint: 'fingerprint-${active.userID}',
                  databaseGeneration: 'generation-${active.userID}'));
    }

    for (final lifecycle in <Future<void> Function(MatrixSdkE2eeClient)>[
      (matrix) => matrix.suspend(),
      (matrix) => matrix.clearLocalChatData(),
    ]) {
      final matrix = await create();
      final preparation = Completer<void>();
      var sends = 0;
      final work = matrix.outgoingWork;
      await work.enqueue(MatrixOutgoingWorkJob(
        id: 'held-${identityHashCode(lifecycle)}',
        source: MatrixOutgoingWorkSource(
          id: 'source-${identityHashCode(lifecycle)}',
          retainedBytes: 1,
          prepare: (_) => preparation.future,
          release: () async {},
        ),
        items: [
          MatrixOutgoingWorkItem(
            id: 'item',
            targetRoomId: '!target:test',
            txid: 'outgoing-held-${identityHashCode(lifecycle)}-0',
            send: (_) async {
              sends++;
              return 'event';
            },
          ),
        ],
      ));

      await lifecycle(matrix);
      expect(matrix.outgoingWork, same(work));
      expect(work.isActive, isFalse);
      preparation.complete();
      await work.drain();
      expect(sends, 0);
    }
  });

  test('owner sends frozen forwarded text with the coordinator transaction id',
      () async {
    final client = _OutgoingTrackingClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingTrackingRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));

    final jobs = await matrix.enqueueForward(
      batchId: 'frozen-forward',
      messages: [
        MatrixOutgoingForwardText(
          id: 'source-message',
          body: 'original selected text',
          format: 'org.matrix.custom.html',
          formattedBody: '<b>original selected text</b>',
        ),
      ],
      targetRoomIds: [target.id],
    );
    await matrix.outgoingWork.drain();

    final item = jobs.single.items.single;
    expect(target.sentTxids, ['outgoing-frozen-forward-0-0']);
    expect(target.sentContents.single['body'], 'original selected text');
    expect(item.eventId, r'$event-1');
    expect(item.presentation.kind, MatrixOutgoingPresentationKind.text);
    expect(item.presentation.text, 'original selected text');
  });

  test('rejected prepared media keeps its source for retry and freezes JSON',
      () async {
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingMediaRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        outgoingWorkFactory: (accountId) => MatrixOutgoingWorkCoordinator(
              accountId: accountId,
              maxRetainedSourceBytes: 2,
            ),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final releaseReservation = Completer<void>();
    await matrix.outgoingWork.enqueue(MatrixOutgoingWorkJob(
      id: 'reservation',
      source: MatrixOutgoingWorkSource(id: 'held', retainedBytes: 2),
      items: [
        MatrixOutgoingWorkItem(
          id: 'held',
          targetRoomId: '!held:test',
          txid: 'outgoing-held-0-0',
          send: (_) => releaseReservation.future.then((_) => r'$held'),
        ),
      ],
    ));
    final nested = <String, dynamic>{'width': 10};
    final media = MatrixOutgoingPreparedMedia(
      id: 'retry-video',
      bytes: [1, 2],
      mimeType: 'video/mp4',
      filename: 'original.mp4',
      body: 'Original video description',
      extraContent: {'custom': nested},
    );
    nested['width'] = 99;

    await expectLater(
      matrix.enqueuePreparedMedia(
        jobId: 'retry-media',
        media: media,
        targetRoomIds: [target.id],
      ),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    releaseReservation.complete();
    await matrix.outgoingWork.drain();

    final retry = await matrix.enqueuePreparedMedia(
      jobId: 'retry-media',
      media: media,
      targetRoomIds: [target.id],
    );
    await matrix.outgoingWork.drain();

    expect(retry.items.single.eventId, r'$media-event');
    expect(target.sentTxids, ['outgoing-retry-media-0-0']);
    expect((target.sentExtraContent.single['custom'] as Map)['width'], 10);
  });

  test('owner admits a controlled video file before its held preparation',
      () async {
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingMediaRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final file = File('${Directory.systemTemp.path}/outgoing-video-test.mp4');
    await file.writeAsBytes([1]);
    final preparation = Completer<MatrixOutgoingPreparedMedia>();

    final job = await matrix.enqueueVideoFile(
      jobId: 'captured-video',
      video: MatrixOutgoingVideoFile.forTesting(
        id: 'capture',
        source: file,
        filename: 'capture.mp4',
        body: '[视频消息]',
        deleteSourceWhenDone: true,
        prepareMedia: (_) => preparation.future,
      ),
      targetRoomIds: [target.id],
    );

    expect(job.items.single.state, MatrixOutgoingWorkState.preparing);
    expect(target.sentTxids, isEmpty);
    expect(await file.exists(), isTrue);
    preparation.complete(MatrixOutgoingPreparedMedia(
      id: 'capture',
      bytes: [1, 2],
      mimeType: 'video/mp4',
      filename: 'capture.mp4',
      body: '[视频消息]',
    ));
    await matrix.outgoingWork.drain();
    expect(target.sentTxids, ['outgoing-captured-video-0-0']);
    expect(await file.exists(), isFalse);
  });

  test('failed video preparation retains its owned capture for retry',
      () async {
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingMediaRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final file = File('${Directory.systemTemp.path}/outgoing-video-retry.mp4');
    await file.writeAsBytes([1]);
    var attempts = 0;
    final job = await matrix.enqueueVideoFile(
        jobId: 'retry-capture',
        video: MatrixOutgoingVideoFile.forTesting(
          id: 'capture',
          source: file,
          filename: 'capture.mp4',
          body: '[视频消息]',
          deleteSourceWhenDone: true,
          prepareMedia: (_) async {
            if (attempts++ == 0) throw const VideoCompressionException();
            return MatrixOutgoingPreparedMedia(
                id: 'capture',
                bytes: [1],
                mimeType: 'video/mp4',
                filename: 'capture.mp4',
                body: '[视频消息]');
          },
        ),
        targetRoomIds: [target.id]);
    await matrix.outgoingWork.drain();
    expect(job.items.single.state, MatrixOutgoingWorkState.failed);
    expect(await file.exists(), isTrue);
    expect(
        matrix.outgoingWork.retainedSourceBytes, 20 * 1024 * 1024 + 512 * 1024,
        reason: 'A failed source keeps its bounded reservation for retry.');
    await matrix.outgoingWork.retryItem(job.id, job.items.single.id);
    await matrix.outgoingWork.drain();
    expect(await file.exists(), isFalse);
    expect(matrix.outgoingWork.retainedSourceBytes, 0);
  });

  test(
      'production video preparation keeps a failed capture then releases it on cancellation',
      () async {
    final artifactRoot = Directory(
        '../../docs/verification/artifacts/2026-09-12/media-interactions/d3-video-prepare');
    await artifactRoot.create(recursive: true);
    final artifact = await artifactRoot.createTemp('failed-capture-');
    final file = File('${artifact.path}/capture.mp4');
    await file.writeAsBytes([1]);
    final channel = const MethodChannel('video_compress');
    var compressions = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': file.path, 'duration': 1000});
      }
      if (call.method == 'compressVideo') {
        compressions++;
        return null;
      }
      return null;
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await artifact.delete(recursive: true);
    });
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingMediaRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));

    final job = await matrix.enqueueVideoFile(
      jobId: 'production-failed-capture',
      video: MatrixOutgoingVideoFile(
        id: 'production-capture',
        source: file,
        filename: 'capture.mp4',
        body: '[视频消息]',
        deleteSourceWhenDone: true,
      ),
      targetRoomIds: [target.id],
    );
    await matrix.outgoingWork.drain();

    expect(compressions, 2);
    expect(job.items.single.state, MatrixOutgoingWorkState.failed);
    expect(await file.exists(), isTrue,
        reason:
            'A failed real compression must leave the camera original for retry.');
    expect(
        matrix.outgoingWork.retainedSourceBytes, 20 * 1024 * 1024 + 512 * 1024);
    matrix.outgoingWork.cancelItem(job.id, job.items.single.id);
    await matrix.outgoingWork.drain();
    expect(await file.exists(), isFalse,
        reason:
            'Cancelling a terminal failed job releases the app-owned capture.');
    expect(matrix.outgoingWork.retainedSourceBytes, 0);
  });

  test('large original video reserves its bounded rendition before preparation',
      () async {
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingMediaRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final artifactRoot = Directory(
        '${Directory.current.path}/../../docs/verification/artifacts/2026-09-12/media-interactions/d2-video-inputs');
    await artifactRoot.create(recursive: true);
    final artifact = await artifactRoot.createTemp('large-original-');
    final file = File('${artifact.path}/capture.mp4');
    try {
      await file.writeAsBytes([1]);
      final job = await matrix.enqueueVideoFile(
        jobId: 'large-original-video',
        video: MatrixOutgoingVideoFile.forTesting(
          id: 'large-original',
          source: file,
          filename: 'capture.mp4',
          body: '[视频消息]',
          deleteSourceWhenDone: true,
          sourceCost: (_) async => 101 * 1024 * 1024,
          prepareMedia: (_) async => MatrixOutgoingPreparedMedia(
            id: 'large-original',
            bytes: [1],
            mimeType: 'video/mp4',
            filename: 'capture.mp4',
            body: '[视频消息]',
          ),
        ),
        targetRoomIds: [target.id],
      );
      expect(job.items.single.state, isNot(MatrixOutgoingWorkState.failed));
      await matrix.outgoingWork.drain();
      expect(target.sentTxids, ['outgoing-large-original-video-0-0']);
    } finally {
      if (await artifact.exists()) await artifact.delete(recursive: true);
    }
  });

  test(
      'owner atomically accepts nine deferred gallery videos within one preparation budget',
      () async {
    const preparationBudget = 21 * 1024 * 1024;
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final target = _OutgoingMediaRoom(id: '!target:test', client: client);
    client.roomsById[target.id] = target;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        outgoingWorkFactory: (accountId) => MatrixOutgoingWorkCoordinator(
              accountId: accountId,
              maxConcurrentTransfers: 1,
              maxReadySources: 1,
              maxRetainedSourceBytes: preparationBudget,
            ),
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final artifactRoot = Directory(
      '../../docs/verification/artifacts/2026-09-12/media-interactions/d3-gallery-batch',
    );
    await artifactRoot.create(recursive: true);
    final directory = await artifactRoot.createTemp('owner-');
    final source = File('${directory.path}/gallery.mp4');
    await source.writeAsBytes([1]);
    final preparation =
        List.generate(9, (_) => Completer<MatrixOutgoingPreparedMedia>());
    final started = <int>[];
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final jobs = await matrix.enqueueVideoFiles(
      requests: [
        for (var index = 0; index < 9; index++)
          MatrixOutgoingVideoFileRequest(
            jobId: 'gallery-$index',
            video: MatrixOutgoingVideoFile.forTesting(
              id: 'gallery-source-$index',
              source: source,
              filename: 'gallery-$index.mp4',
              body: '[视频消息]',
              deleteSourceWhenDone: false,
              prepareMedia: (_) {
                started.add(index);
                return preparation[index].future;
              },
            ),
            targetRoomIds: [target.id],
          ),
      ],
    );

    expect(jobs, hasLength(9));
    expect(
        matrix.outgoingWork.retainedSourceBytes, 20 * 1024 * 1024 + 512 * 1024);
    // 首次 prepare 之前存在真实文件 I/O（`_waitForSourceMetadata`），因此
    // "一个微任务轮次后就已开始" 不是可靠假设（并行负载下会 flake）。
    // 改为有界轮询等待"第一个准备确实已经开始"，断言语义不变（一次只允许
    // 一个 gallery handle 准备）。
    await _pumpUntil(() => started.isNotEmpty,
        reason: '第一个 gallery 源的准备应在有界时间内开始');
    expect(started, [0],
        reason: 'Only one accepted gallery handle may prepare at a time.');
    for (var index = 0; index < preparation.length; index++) {
      preparation[index].complete(MatrixOutgoingPreparedMedia(
        id: 'gallery-source-$index',
        bytes: [index],
        mimeType: 'video/mp4',
        filename: 'gallery-$index.mp4',
        body: '[视频消息]',
      ));
      if (index + 1 < preparation.length) {
        // 等到下一个准备真正开始，再断言预算（否则断言可能落在"还没开始"的
        // 空窗里而失去意义）。
        await _pumpUntil(() => started.length > index + 1,
            reason: '第 ${index + 1} 个 gallery 源的准备应在有界时间内开始');
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      expect(matrix.outgoingWork.retainedSourceBytes,
          lessThanOrEqualTo(preparationBudget));
    }
    await matrix.outgoingWork.drain();
    expect(started, List<int>.generate(9, (index) => index));
    expect(target.sentTxids, hasLength(9));
  });
  test(
      'video admission freezes targets and rejects duplicate batch sources without ownership transfer',
      () async {
    final client = _OutgoingMediaClient('alice',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'ALICE');
    final firstTarget = _OutgoingMediaRoom(id: '!first:test', client: client);
    final replacementTarget =
        _OutgoingMediaRoom(id: '!replacement:test', client: client);
    client.roomsById[firstTarget.id] = firstTarget;
    client.roomsById[replacementTarget.id] = replacementTarget;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final artifactRoot = Directory(
      '../../docs/verification/artifacts/2026-09-12/media-interactions/d3-video-admission',
    );
    await artifactRoot.create(recursive: true);
    final directory = await artifactRoot.createTemp('frozen-');
    final source = File('${directory.path}/source.mp4');
    await source.writeAsBytes([1]);
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final sourceMetadata = Completer<int>();
    final targets = [firstTarget.id];
    final frozenJob = matrix.enqueueVideoFile(
      jobId: 'frozen-targets',
      video: MatrixOutgoingVideoFile.forTesting(
        id: 'frozen-target-source',
        source: source,
        filename: 'source.mp4',
        body: '[视频消息]',
        deleteSourceWhenDone: false,
        sourceCost: (_) => sourceMetadata.future,
        prepareMedia: (_) async => MatrixOutgoingPreparedMedia(
          id: 'frozen-target-source',
          bytes: [1],
          mimeType: 'video/mp4',
          filename: 'source.mp4',
          body: '[视频消息]',
        ),
      ),
      targetRoomIds: targets,
    );
    await Future<void>.delayed(Duration.zero);
    targets[0] = replacementTarget.id;
    sourceMetadata.complete(1);
    await frozenJob;
    await matrix.outgoingWork.drain();
    expect(firstTarget.sentTxids, ['outgoing-frozen-targets-0-0']);
    expect(replacementTarget.sentTxids, isEmpty);

    final sharedVideo = MatrixOutgoingVideoFile.forTesting(
      id: 'duplicate-source',
      source: source,
      filename: 'source.mp4',
      body: '[视频消息]',
      deleteSourceWhenDone: false,
      prepareMedia: (_) async => MatrixOutgoingPreparedMedia(
        id: 'duplicate-source',
        bytes: [2],
        mimeType: 'video/mp4',
        filename: 'source.mp4',
        body: '[视频消息]',
      ),
    );
    await expectLater(
      matrix.enqueueVideoFiles(requests: [
        MatrixOutgoingVideoFileRequest(
          jobId: 'duplicate-first',
          video: sharedVideo,
          targetRoomIds: [firstTarget.id],
        ),
        MatrixOutgoingVideoFileRequest(
          jobId: 'duplicate-second',
          video: sharedVideo,
          targetRoomIds: [firstTarget.id],
        ),
      ]),
      throwsArgumentError,
    );
    await matrix.enqueueVideoFile(
      jobId: 'after-duplicate-reject',
      video: sharedVideo,
      targetRoomIds: [firstTarget.id],
    );
    await matrix.outgoingWork.drain();
    expect(firstTarget.sentTxids,
        ['outgoing-frozen-targets-0-0', 'outgoing-after-duplicate-reject-0-0']);
  });
  test('old lease cannot admit a held video into replacement account B',
      () async {
    final a = _OutgoingMediaClient('alice',
        loggedIn: true, matrixUserId: '@a:matrix.test', matrixDeviceId: 'A');
    final b = _OutgoingMediaClient('bob',
        loggedIn: true, matrixUserId: '@b:matrix.test', matrixDeviceId: 'B');
    final roomA = _OutgoingMediaRoom(id: '!shared:test', client: a);
    final roomB = _OutgoingMediaRoom(id: '!shared:test', client: b);
    a.roomsById[roomA.id] = roomA;
    b.roomsById[roomB.id] = roomB;
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        selectClientAccount: (_, __) async {},
        resumeClient: () async => b,
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'fingerprint-${active.userID}',
                databaseGeneration: 'generation-${active.userID}'));
    final lease = await matrix.openRoomLease(roomA.id);
    final file = File('${Directory.systemTemp.path}/outgoing-video-switch.mp4');
    await file.writeAsBytes([1]);
    final sourceCost = Completer<int>();
    final admission = lease.enqueueVideoFile(
      jobId: 'old-account-video',
      video: MatrixOutgoingVideoFile.forTesting(
        id: 'capture',
        source: file,
        filename: 'capture.mp4',
        body: '[视频消息]',
        deleteSourceWhenDone: false,
        sourceCost: (_) => sourceCost.future,
        prepareMedia: (_) async => throw StateError('must not prepare'),
      ),
      targetRoomIds: [roomA.id],
    );
    await Future<void>.delayed(Duration.zero);
    await matrix.selectAccount(
        '@b:matrix.test', Uri.parse('https://matrix.example'));
    sourceCost.complete(1);
    await expectLater(admission, throwsStateError);
    expect(roomB.sentTxids, isEmpty);
    expect(matrix.outgoingWork.job('old-account-video'), isNull);
    await file.delete();
  });

  test(
      'factory reopens account-specific file and original legacy file unchanged',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    final opened = <({String path, String cipher})>[];
    final factory = MatrixClientFactory(
        sessionStore: store,
        homeserver: Uri.parse('https://matrix.example'),
        supportDirectoryPath: () async => '/private/support',
        // This path-only fixture does not write SQLCipher files. Model the
        // retained A identity explicitly; physical read-only probing has its
        // own tests.
        localIdentityPreflight: MatrixLocalIdentityPreflight(
          reader: _OriginalIdentityFixtureReader(),
          fingerprintReader: (_, pickle) async => pickle,
        ),
        clientMigrator: (_, __) async {},
        opener: (
            {required clientName,
            required databasePath,
            required cipher}) async {
          opened.add((path: databasePath, cipher: cipher));
          return LogoutTrackingClient('fixture');
        });
    await factory.create();
    await (factory as dynamic)
        .selectAccount('https://matrix.example', '@b:test');
    await factory.create();
    await (factory as dynamic)
        .selectAccount('https://matrix.example', '@a:test');
    await factory.create();
    expect(opened[0].path, endsWith('liuhetong_matrix.sqlite'));
    expect(opened[1].path, isNot(opened[0].path));
    expect(opened[1].cipher, isNot(opened[0].cipher));
    expect(opened[2], opened[0]);
  });
}

final class _OriginalIdentityFixtureReader
    implements MatrixLocalIdentityReader {
  @override
  Future<bool> exists(String databasePath) async =>
      databasePath.endsWith('liuhetong_matrix.sqlite');

  @override
  Future<MatrixLocalIdentityRecord> read(
          String databasePath, String cipher) async =>
      const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@a:test',
        deviceId: 'device-A',
        olmAccount: 'fingerprint-@a:test',
      );
}

class _OutgoingTrackingClient extends LogoutTrackingClient {
  _OutgoingTrackingClient(super.name,
      {super.loggedIn, super.matrixUserId, super.matrixDeviceId});

  final Map<String, Room> roomsById = {};

  @override
  Room? getRoomById(String roomId) => roomsById[roomId];
}

final class _OutgoingMediaClient extends _OutgoingTrackingClient {
  _OutgoingMediaClient(super.name,
      {super.loggedIn, super.matrixUserId, super.matrixDeviceId});

  @override
  bool get fileEncryptionEnabled => true;
}

class _OutgoingTrackingRoom extends Room {
  _OutgoingTrackingRoom({required super.id, required super.client})
      : super(membership: Membership.join);

  final List<String?> sentTxids = [];
  final List<Map<String, dynamic>> sentContents = [];

  @override
  bool get encrypted => true;
  @override
  bool get canSendDefaultMessages => true;

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sentTxids.add(txid);
    sentContents.add(Map<String, dynamic>.from(content));
    return r'$event-1';
  }
}

final class _OutgoingMediaRoom extends _OutgoingTrackingRoom {
  _OutgoingMediaRoom({required super.id, required super.client});

  final List<Map<String, dynamic>> sentExtraContent = [];

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sentTxids.add(txid);
    sentExtraContent.add(Map<String, dynamic>.from(extraContent ?? {}));
    return r'$media-event';
  }
}

/// 有界轮询：每轮让出事件循环，直到 [condition] 成立或超时失败。
///
/// 这些用例断言的是"顺序 / 并发上限 / 预算"这类不变量，而不是"恰好一个微任务
/// 之后的状态"。用固定的 `Duration.zero` 会在并行负载（CI 同机多测试进程）下
/// flake —— 首次 prepare 之前存在真实文件 I/O（`_waitForSourceMetadata`）。
/// 轮询保留了原有不变量，只去掉时序假设。
Future<void> _pumpUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时（${timeout.inSeconds}s）：$reason');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
