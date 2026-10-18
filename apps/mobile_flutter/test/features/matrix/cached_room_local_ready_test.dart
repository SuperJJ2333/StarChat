import 'dart:async';
import 'dart:convert';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:matrix/encryption.dart';
import 'package:olm/olm.dart' as olm;

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

class _Client extends Client {
  _Client(this.store) : super('cached-local-ready');
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
  @override
  String get userID => '@cached:synthetic.test';
  late final room = _Room(client: this);
  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

class _EncryptedClient extends _Client {
  _EncryptedClient(super.store);
  late final crypto = _HeldLocalEncryption(client: this);
  Completer<void>? startupRecovery;
  @override
  bool get isInitializationPending =>
      startupRecovery != null && !startupRecovery!.isCompleted;
  @override
  Future<void> get initializationCompleted =>
      startupRecovery?.future ?? super.initializationCompleted;
  @override
  Encryption get encryption => crypto;
  @override
  bool get encryptionEnabled => true;
}

class _HeldLocalEncryption extends Encryption {
  _HeldLocalEncryption({required super.client});
  bool holdTail = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Event> decryptRoomEvent(String roomId, Event event,
      {bool store = false,
      EventUpdateType updateType = EventUpdateType.timeline}) async {
    if (holdTail && !store && event.eventId == 'encrypted-1') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super
        .decryptRoomEvent(roomId, event, store: store, updateType: updateType);
  }
}

class _Room extends Room {
  _Room({required super.client}) : super(id: '!cached:synthetic.test');
  final postLoadEntered = Completer<void>();
  final releasePostLoad = Completer<void>();
  @override
  Future<void> postLoad() async {
    if (!postLoadEntered.isCompleted) postLoadEntered.complete();
    await releasePostLoad.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(SQfLiteEncryptionHelper.ffiInit);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final pin in ['none', 'before', 'during', 'hidden', 'startup']) {
    test(
        'retained cached forty decrypt with local keys and no broadcast; pin=$pin',
        () async {
      await olm.init();
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final sql = await factory.openDatabase(inMemoryDatabasePath);
      final db = MatrixSdkDatabase('cached-encrypted',
          database: sql, sqfliteFactory: factory);
      await db.open();
      final client = _EncryptedClient(db)
        ..accessToken = 'synthetic-token'
        ..homeserver = Uri.parse('https://synthetic.test');
      final room = client.room;
      client.crypto.holdTail =
          pin == 'before' || pin == 'hidden' || pin == 'during';
      if (pin == 'startup') client.startupRecovery = Completer<void>();
      room.setState(Event(
          room: room,
          eventId: 'encryption',
          senderId: client.userID,
          originServerTs: DateTime.utc(2026),
          type: EventTypes.Encryption,
          stateKey: '',
          content: {'algorithm': AlgorithmTypes.megolmV1AesSha2}));
      final outbound = olm.OutboundGroupSession()..create();
      final sessionId = outbound.session_id();
      await client.crypto.keyManager
          .setInboundGroupSession(room.id, sessionId, 'synthetic-sender', {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'session_key': outbound.session_key(),
      });
      expect(await db.getInboundGroupSession(room.id, sessionId), isNotNull,
          reason: 'the valid local key must be persisted, not only in memory');
      client.crypto.keyManager.clearInboundGroupSessions();
      for (var i = 0; i < 40; i++) {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'encrypted-$i',
                  'type': pin != 'none' && i % 4 != 1
                      ? EventTypes.Message
                      : EventTypes.Encrypted,
                  'sender': client.userID,
                  'origin_server_ts': 1000 + i,
                  'content': pin != 'none' && i % 4 != 1
                      ? {'msgtype': MessageTypes.Text, 'body': 'decrypted $i'}
                      : {
                          'algorithm': AlgorithmTypes.megolmV1AesSha2,
                          'session_id': sessionId,
                          'sender_key': 'synthetic-sender',
                          'msgtype': MessageTypes.BadEncrypted,
                          'can_request_session': true,
                          'ciphertext': outbound.encrypt(jsonEncode({
                            'room_id': room.id,
                            'type': EventTypes.Message,
                            'content': {
                              'msgtype': MessageTypes.Text,
                              'body': 'decrypted $i'
                            }
                          })),
                        },
                }),
            client);
      }
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://synthetic.test'),
          readContinuityMetadata: (_) async =>
              const MatrixClientContinuityMetadata(
                  isLoggedIn: false,
                  userId: '@cached:synthetic.test',
                  deviceId: null,
                  ed25519Fingerprint: 'synthetic',
                  databaseGeneration: 'synthetic'));
      final lease = await owner.openRoomLease(room.id);
      final hydrated = Completer<void>();
      var broadcasts = 0;
      final events = client.onEvent.stream.listen((_) => broadcasts++);
      final keys = room.onSessionKeyReceived.stream.listen((_) => broadcasts++);
      final timeline = await lease.openLogicalRoomTimeline(
          cachedFirst: true, onHydrated: hydrated.complete, onUpdate: () {});
      final controller = RoomTimelineController(
          MatrixRoomTimelineAdapter(timeline),
          windowed: true,
          canDispatchNow: () => false);
      RoomMessageViewModel? anchor;
      try {
        if (pin == 'startup') {
          for (var i = 0; i < 100 && timeline.snapshot().length < 40; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(timeline.snapshot(), hasLength(40));
          expect(room.postLoadEntered.isCompleted, isFalse);
          expect(client.startupRecovery!.isCompleted, isFalse);
          client.startupRecovery!.complete();
        }
        if (client.crypto.holdTail) {
          await client.crypto.entered.future
              .timeout(const Duration(seconds: 10));
          expect(room.postLoadEntered.isCompleted, isFalse,
              reason: 'local decoding must precede complete room recovery');
        } else {
          await room.postLoadEntered.future;
          expect(timeline.snapshot(), hasLength(40));
        }
        if (pin != 'none') {
          controller.restoreOutboxMessage(OutboxMessage(
              localId: 'pending-local',
              txid: 'pending-txid',
              receiverId: 'peer',
              content: 'retained pending',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1035),
              updatedAt: DateTime.fromMillisecondsSinceEpoch(1035),
              status: OutboxStatus.sending));
          anchor =
              controller.messages.singleWhere((m) => m.id == 'encrypted-15');
        }
        if (pin == 'hidden') {
          controller.setHiddenFilter((id, _) => id == 'encrypted-5');
        }
        if (pin == 'before' || pin == 'hidden' || pin == 'startup') {
          controller.pinWindow();
        }
        if (client.crypto.holdTail) {
          if (pin == 'during') {
            controller.pinWindow();
          }
          client.crypto.release.complete();
        }
        await room.postLoadEntered.future;
        room.releasePostLoad.complete();
        await hydrated.future.timeout(const Duration(seconds: 10));
        expect(broadcasts, 0);
        expect(timeline.snapshot(), hasLength(pin == 'hidden' ? 39 : 40));
        expect(timeline.snapshot().first.text, 'decrypted 0',
            reason: 'oldest ten are outside SDK default thirty');
        expect(timeline.snapshot().last.text, 'decrypted 39');
        await controller.refresh();
        if (pin != 'none') {
          expect(controller.isViewingHistoryContext, isTrue,
              reason:
                  'hydration must not switch the active reading fragment to latest');
          expect(
              identical(
                  controller.messages.singleWhere((m) => m.id == anchor!.id),
                  anchor),
              isTrue);
          final pending = controller.messages
              .singleWhere((m) => m.transactionId == 'pending-txid');
          expect(pending.stableId, 'pending-txid');
          expect(pending.deliveryState, RoomDeliveryState.sending);
          expect(controller.messages, hasLength(pin == 'hidden' ? 40 : 41));
          if (pin == 'hidden') {
            expect(
                controller.messages.any((m) => m.id == 'encrypted-5'), isFalse);
          }
        }
      } finally {
        if (!client.crypto.release.isCompleted) {
          client.crypto.release.complete();
        }
        controller.dispose();
        await lease.cancel();
        await events.cancel();
        await keys.cancel();
        outbound.free();
        await client.dispose();
        await db.close();
      }
    });
  }

  for (final retire in [false, true]) {
    test('SQLCipher cached head precedes SDK postLoad; retire=$retire',
        () async {
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final sql = await factory.openDatabase(inMemoryDatabasePath);
      final db = MatrixSdkDatabase('cached-local-ready',
          database: sql, sqfliteFactory: factory);
      await db.open();
      final client = _Client(db);
      final room = client.room;
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://synthetic.test'),
          readContinuityMetadata: (_) async =>
              const MatrixClientContinuityMetadata(
                  isLoggedIn: false,
                  userId: '@cached:synthetic.test',
                  deviceId: null,
                  ed25519Fingerprint: 'synthetic',
                  databaseGeneration: 'synthetic'));
      for (var i = 0; i < 80; i++) {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'cached-$i',
                  'type': EventTypes.Message,
                  'sender': '@peer:synthetic.test',
                  'origin_server_ts': 1000 + i,
                  'content': {
                    'msgtype': MessageTypes.Text,
                    'body': 'cached body $i'
                  },
                }),
            client);
      }
      final lease = await owner.openRoomLease(room.id);
      var hydrated = false;
      final timeline = await lease.openLogicalRoomTimeline(
          cachedFirst: true,
          onHydrated: () => hydrated = true,
          onUpdate: () {});
      await room.postLoadEntered.future;
      expect(hydrated, isFalse);
      // Production installs this authoritative callback. Even an allow result
      // cannot send from missing encryption state while postLoad is held.
      owner.authorizeRoomSend = (_, __, ___) async => true;
      await expectLater(
          timeline.sendText('must never be plaintext'), throwsStateError);
      expect(timeline.snapshot(), hasLength(40));
      expect(timeline.snapshot().last.text, 'cached body 79');
      if (retire) lease.revokeNow();
      room.releasePostLoad.complete();
      for (var i = 0; i < 20 && !hydrated && !retire; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (retire) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(hydrated, isFalse);
        expect(() => timeline.snapshot(), throwsStateError);
      } else {
        expect(hydrated, isTrue);
        expect(timeline.snapshot().last.text, 'cached body 79');
      }
      timeline.dispose();
      await lease.cancel();
      await client.dispose();
      await db.close();
    });
  }
}
