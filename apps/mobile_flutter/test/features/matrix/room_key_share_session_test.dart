import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:path/path.dart' as p;

import '../../support/retained_recovery_identity_fixture.dart';

class _Storage implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Room extends Room {
  _Room(Client client)
      : super(client: client, id: RetainedRecoveryIdentityFixture.roomId);
  List<DeviceKeys> devices = [];
  @override
  bool get encrypted => true;
  @override
  String get encryptionAlgorithm => AlgorithmTypes.megolmV1AesSha2;
  @override
  Future<List<DeviceKeys>> getUserDeviceKeys() async => List.of(devices);
  @override
  List<User> getParticipants(
          [List<Membership> filter = const [
            Membership.join,
            Membership.invite,
            Membership.knock
          ]]) =>
      devices
          .map((d) => d.userId)
          .toSet()
          .map((id) => User(id, room: this, membership: 'join'))
          .toList();
}

class _Peer {
  _Peer([this.device = 'PEER']) {
    account.create();
    account.generate_one_time_keys(1);
    identity = Map<String, dynamic>.from(jsonDecode(account.identity_keys()));
  }
  static const user = '@peer:synthetic.test';
  final String device;
  final account = olm.Account();
  late Map<String, dynamic> identity;
  final received = <olm.InboundGroupSession>[];
  olm.Session? pairwise;
  bool omitKeys = false;
  bool failShare = false;
  Completer<void>? shareEntered;
  Completer<void>? shareRelease;
  Completer<void>? claimEntered;
  Completer<void>? claimRelease;
  int shares = 0;
  void Function()? beforeShareResponse;

  Map<String, dynamic> sign(Map<String, dynamic> payload) => {
        ...payload,
        'signatures': {
          user: {'ed25519:$device': account.sign(jsonEncode(payload))}
        }
      };

  DeviceKeys keys(Client client) => DeviceKeys.fromMatrixDeviceKeys(
      MatrixDeviceKeys.fromJson(sign({
        'algorithms': [
          AlgorithmTypes.olmV1Curve25519AesSha2,
          AlgorithmTypes.megolmV1AesSha2
        ],
        'device_id': device,
        'keys': {
          'curve25519:$device': identity['curve25519'],
          'ed25519:$device': identity['ed25519']
        },
        'user_id': user,
      })),
      client);

  Future<http.Response?> respond(http.Request request) async {
    if (request.url.path.endsWith('/keys/claim')) {
      if (claimEntered?.isCompleted == false) claimEntered!.complete();
      await claimRelease?.future;
      final otk = (jsonDecode(account.one_time_keys())['curve25519'] as Map)
          .values
          .first;
      return http.Response(
          jsonEncode({
            'one_time_keys': omitKeys
                ? {}
                : {
                    user: {
                      device: {
                        'signed_curve25519:synthetic': sign({'key': otk})
                      }
                    }
                  }
          }),
          200);
    }
    if (request.url.path.contains('/sendToDevice/')) {
      shares++;
      if (shareEntered?.isCompleted == false) shareEntered!.complete();
      await shareRelease?.future;
      beforeShareResponse?.call();
      if (failShare) {
        return http.Response('{"errcode":"M_UNKNOWN","error":"synthetic"}', 503,
            headers: {'content-type': 'application/json'});
      }
      final messages = jsonDecode(request.body)['messages'] as Map;
      final event = messages[user]?[device];
      if (event != null) {
        final encrypted = event['ciphertext'][identity['curve25519']];
        pairwise ??= olm.Session()
          ..create_inbound_from(
              account, event['sender_key'], encrypted['body']);
        final plain =
            jsonDecode(pairwise!.decrypt(encrypted['type'], encrypted['body']));
        expect(plain['type'], EventTypes.RoomKey);
        received.add(
            olm.InboundGroupSession()..create(plain['content']['session_key']));
      }
      return http.Response('{}', 200);
    }
    return null;
  }

  void dispose() {
    for (final inbound in received) {
      inbound.free();
    }
    pairwise?.free();
    account.free();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(olm.init);
  for (final scenario in [
    'roundtrip',
    'omitted key',
    'legacy missing authorization',
    'device public key changed',
    'device added',
    'device removed',
    'store failure',
    'precommit revocation',
    'postcommit revocation',
    'share failure',
    'changed while sharing',
    'member removed during claim',
    'registry replaced during claim',
    'member removed during queue',
    'no external target',
    'concurrent sends'
  ]) {
    test('real room key sharing $scenario',
        () => verifyRoomKeyShareScenario(scenario));
  }
}

Future<void> verifyRoomKeyShareScenario(String scenario) async {
  final root = Platform.isAndroid || Platform.isIOS
      ? Directory.systemTemp
      : Directory(p.absolute(
          '../../docs/verification/artifacts/2026-10-19/account-switch-readiness'));
  final directory = await root.createTemp('room-key-share-');
  final sessions = SecureSessionStore(_Storage());
  await sessions.selectMatrixAccount(
      RetainedRecoveryIdentityFixture.endpoint.toString(),
      RetainedRecoveryIdentityFixture.user);
  final fixture = RetainedRecoveryIdentityFixture(
      p.join(directory.path, 'fixture.sqlite'),
      await sessions.matrixDatabaseKey(),
      sessions);
  final peer = _Peer();
  final replacedPeers = <_Peer>[];
  fixture.additionalResponse = peer.respond;
  await fixture.openClient(seed: true);
  await fixture.client.sync();
  var client = fixture.client;
  var room = _Room(client);
  void bind(_Peer target) {
    final keys = target.keys(client);
    expect(keys.isValid, isTrue);
    client.userDeviceKeys[_Peer.user] = DeviceKeysList(_Peer.user, client)
      ..outdated = false
      ..deviceKeys = {target.device: keys};
    room.devices = [keys];
    client.rooms
      ..clear()
      ..add(room);
  }

  bind(peer);
  var owner = RecoveryOperationOwner(identity: Object(), isCurrent: () => true);
  client.recoveryOwner = owner;
  final manager = client.encryption!.keyManager;
  Future<Map<String, dynamic>> send() =>
      client.encryption!.encryptGroupMessagePayload(
          room.id, {'msgtype': 'm.text', 'body': 'synthetic'});
  try {
    if (scenario.endsWith('during claim') ||
        scenario.endsWith('during queue')) {
      final entered = Completer<void>();
      final release = Completer<void>();
      if (scenario.endsWith('during queue')) {
        client.beforeToDeviceQueue = () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        };
      } else {
        peer.claimEntered = entered;
        peer.claimRelease = release;
      }
      final pending = send();
      final failure = expectLater(pending, throwsStateError);
      await entered.future;
      if (scenario.startsWith('member')) {
        room.devices = [];
      } else {
        final replacement = _Peer();
        replacedPeers.add(replacement);
        bind(replacement);
      }
      release.complete();
      await failure;
      expect(peer.shares, 0,
          reason: 'A stale target must be rejected before key-sharing HTTP.');
      expect(manager.getOutboundGroupSession(room.id), isNull);
      expect((await fixture.database.getToDeviceEventQueue()).isEmpty, isTrue,
          reason:
              'A rejected key share must not be queued for later unguarded dispatch.');
      client.beforeToDeviceQueue = null;
      await client.processToDeviceQueue();
      expect(peer.shares, 0);
      await client.recoveryOwner?.drain();
      await client.dispose();
      await fixture.openClient();
      client = fixture.client;
      await client.processToDeviceQueue();
      expect(peer.shares, 0,
          reason: 'Reopen must not replay a rejected room key.');
      expect((await fixture.database.getToDeviceEventQueue()).isEmpty, isTrue);
      return;
    }
    if (scenario == 'no external target') {
      room.devices = [];
      final encrypted = await send();
      expect(peer.shares, 0);
      final inbound =
          manager.getInboundGroupSession(room.id, encrypted['session_id'])!;
      expect(
          jsonDecode(inbound.inboundGroupSession!
                  .decrypt(encrypted['ciphertext'])
                  .plaintext)['content']['body'] ==
              'synthetic',
          isTrue);
      return;
    }
    if (scenario == 'share failure') {
      peer.failShare = true;
      await expectLater(send(), throwsA(isA<Exception>()));
      expect(manager.getOutboundGroupSession(room.id), isNull);
      expect(
          await fixture.database
              .getOutboundGroupSession(room.id, client.userID!),
          isNull);
      peer.failShare = false;
      expect((await fixture.database.getToDeviceEventQueue()).isEmpty, isTrue);
    }
    if (scenario == 'changed while sharing') {
      peer.beforeShareResponse = () => room.devices = [];
      await expectLater(send(), throwsStateError);
      expect(manager.getOutboundGroupSession(room.id), isNull);
      expect(
          await fixture.database
              .getOutboundGroupSession(room.id, client.userID!),
          isNull);
      peer.beforeShareResponse = null;
      bind(peer);
    }
    if (scenario == 'omitted key') {
      peer.omitKeys = true;
      await expectLater(send(), throwsStateError);
      expect(manager.getOutboundGroupSession(room.id), isNull);
      expect(
          await fixture.database
              .getOutboundGroupSession(room.id, client.userID!),
          isNull);
      peer.omitKeys = false;
    }
    if (scenario == 'postcommit revocation') {
      fixture.database.afterTransaction = () async {
        final stored = await fixture.database
            .getOutboundGroupSession(room.id, client.userID!);
        if (stored != null) {
          stored.dispose();
          owner.revoke();
        }
      };
    }
    if (scenario == 'store failure' ||
        scenario == 'precommit revocation' ||
        scenario == 'postcommit revocation') {
      final committed = scenario == 'postcommit revocation';
      if (!committed) {
        fixture.database.afterOutboundStore = () async {
          if (scenario == 'precommit revocation') {
            owner.revoke();
          } else {
            throw StateError('SYNTHETIC_STORE_FAILURE');
          }
        };
      }
      await expectLater(send(), throwsStateError);
      expect(manager.getOutboundGroupSession(room.id), isNull);
      fixture.database.afterOutboundStore = null;
      fixture.database.afterTransaction = null;
      await owner.drain();
      await client.dispose();
      await fixture.openClient();
      client = fixture.client;
      room = _Room(client);
      bind(peer);
      owner = RecoveryOperationOwner(identity: Object(), isCurrent: () => true);
      client.recoveryOwner = owner;
      final reopened = await fixture.database
          .getOutboundGroupSession(room.id, client.userID!);
      if (committed) {
        expect(reopened, isNotNull,
            reason: 'A valid completed commit is not claimed rolled back.');
        reopened!.dispose();
      } else {
        expect(reopened, isNull,
            reason:
                'Failed transaction must not revive a send-ready outbound after reopen.');
      }
    }
    _Peer? extra;
    void addExtra() {
      extra = _Peer('SECOND');
      replacedPeers.add(extra!);
      final keys = extra!.keys(client);
      client.userDeviceKeys[_Peer.user]!.deviceKeys[extra!.device] = keys;
      room.devices.add(keys);
      fixture.additionalResponse = (request) async {
        if (request.url.path.endsWith('/keys/claim')) {
          final requested =
              jsonDecode(request.body)['one_time_keys'][_Peer.user] as Map;
          final keys = <String, dynamic>{};
          for (final target in [peer, extra!]) {
            if (requested.containsKey(target.device)) {
              final otk =
                  (jsonDecode(target.account.one_time_keys())['curve25519']
                          as Map)
                      .values
                      .first;
              keys[target.device] = {
                'signed_curve25519:synthetic': target.sign({'key': otk})
              };
            }
          }
          return http.Response(
              jsonEncode({
                'one_time_keys': {_Peer.user: keys}
              }),
              200);
        }
        final response = await peer.respond(request);
        if (request.url.path.contains('/sendToDevice/')) {
          await extra!.respond(request);
        }
        return response;
      };
    }

    if (scenario == 'device removed') addExtra();
    if (scenario == 'concurrent sends') {
      peer.shareEntered = Completer<void>();
      peer.shareRelease = Completer<void>();
      final first = send();
      await peer.shareEntered!.future;
      final second = send();
      peer.shareRelease!.complete();
      final encrypted = await Future.wait([first, second]);
      expect(encrypted.map((e) => e['session_id']).toSet(), hasLength(1));
      expect(peer.shares, 1);
      expect(
          encrypted.every((e) =>
              jsonDecode(peer.received.single
                  .decrypt(e['ciphertext'])
                  .plaintext)['content']['body'] ==
              'synthetic'),
          isTrue);
    } else {
      final first = await send();
      expect(
          jsonDecode(peer.received.last.decrypt(first['ciphertext']).plaintext)[
                  'content']['body'] ==
              'synthetic',
          isTrue);
      if (scenario == 'device added' || scenario == 'device removed') {
        if (scenario == 'device added') {
          addExtra();
        } else {
          room.devices.removeWhere((key) => key.deviceId == 'SECOND');
          client.userDeviceKeys[_Peer.user]!.deviceKeys.remove('SECOND');
        }
        final next = await send();
        expect(next['session_id'], isNot(first['session_id']));
        expect(
            jsonDecode(peer.received.last
                    .decrypt(next['ciphertext'])
                    .plaintext)['content']['body'] ==
                'synthetic',
            isTrue);
        if (scenario == 'device added') {
          expect(
              jsonDecode(extra!.received.single
                      .decrypt(next['ciphertext'])
                      .plaintext)['content']['body'] ==
                  'synthetic',
              isTrue);
        }
      }

      if (scenario == 'legacy missing authorization') {
        final inbound = client.encryption!.keyManager
            .getInboundGroupSession(room.id, first['session_id'])!;
        inbound.allowedAtIndex.clear();
        await fixture.database.updateInboundGroupSessionAllowedAtIndex(
            '{}', room.id, first['session_id']);
        final next = await send();
        expect(next['session_id'], isNot(first['session_id']));
        expect(inbound.allowedAtIndex, isEmpty,
            reason: 'Do not fabricate old history authorization.');
        expect(
            client.encryption!.keyManager
                .getInboundGroupSession(room.id, first['session_id']),
            same(inbound));
      }
      if (scenario == 'device public key changed') {
        final replacement = _Peer();
        replacedPeers.add(replacement);
        fixture.additionalResponse = replacement.respond;
        bind(replacement);
        final next = await send();
        expect(next['session_id'], isNot(first['session_id']));
        expect(
            jsonDecode(replacement.received.single
                    .decrypt(next['ciphertext'])
                    .plaintext)['content']['body'] ==
                'synthetic',
            isTrue);
      }
    }
  } finally {
    await client.recoveryOwner?.drain();
    await client.dispose();
    peer.dispose();
    for (final replacement in replacedPeers) {
      replacement.dispose();
    }
    await directory.delete(recursive: true);
  }
}
