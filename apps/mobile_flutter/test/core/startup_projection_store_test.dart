import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_store.dart';

class _Secure implements SecureKeyValueStore, PeekableSecureKeyValueStore {
  final values = <String, String>{};
  int writes = 0;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<String?> peek(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    writes++;
    values.remove(key);
  }
}

void main() {
  test('bounded group avatar members round trip while old cache stays valid',
      () {
    final old = StartupProjectionRoom(
        id: '!group:synthetic.test',
        name: 'Group',
        direct: false,
        peer: null,
        unread: 0,
        pinned: false,
        muted: false,
        canSend: true,
        activity: 0,
        events: []).toJson();
    old.remove('members');
    final json = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
    json['members'] = [
      {
        'id': '@member:synthetic.test',
        'name': 'Member',
        'avatar': 'mxc://synthetic.test/avatar'
      }
    ];
    final restored = StartupProjectionRoom.fromJson(json).toJson();
    expect(restored['members'], json['members']);
    expect(
        StartupProjectionRoom.fromJson(jsonDecode(jsonEncode(old)))
            .toJson()['members'],
        isEmpty);
    json['members'] = List.filled(10, (json['members'] as List).first);
    expect(() => StartupProjectionRoom.fromJson(json), throwsFormatException);
    for (final invalid in [
      {'id': 'peer', 'name': 'Member', 'avatar': 'file:///private'},
      {'id': 'peer', 'name': List.filled(257, 'x').join(), 'avatar': null},
      {'id': 'peer', 'name': 'Member', 'avatar': null, 'token': 'synthetic'},
    ]) {
      json['members'] = [invalid];
      expect(() => StartupProjectionRoom.fromJson(json), throwsFormatException);
    }
  });
  late Directory directory;
  late StartupProjectionStore store;
  StartupProjectionAdmission admission(
          {String? epoch,
          String? digest,
          int? length,
          String user = '@synthetic:test'}) =>
      StartupProjectionAdmission(
          scope: '',
          homeserver: 'https://synthetic.test',
          userId: user,
          deviceId: 'SYNTHETIC',
          fingerprint: 'synthetic-fingerprint',
          databaseGeneration: 'synthetic-generation',
          installationId:
              base64Url.encode(List.filled(32, 1)).replaceAll('=', ''),
          epoch:
              epoch ?? base64Url.encode(List.filled(32, 2)).replaceAll('=', ''),
          databaseKey: base64Url.encode(List.filled(32, 3)),
          registrationKey: 'synthetic',
          digest: digest,
          length: length);
  setUp(() async {
    final base = Directory(
        '../../docs/verification/artifacts/2026-10-17/startup-local-projection/fixtures');
    await base.create(recursive: true);
    directory = await base.createTemp('aead-');
    store = StartupProjectionStore(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
      'valid empty encrypted cache survives reopen, cross identity and tamper fail closed',
      () async {
    final candidate = await store.prepare(admission(), StartupProjection([]));
    final accepted =
        admission(digest: candidate.digest, length: candidate.length);
    expect((await store.read(accepted))!.rooms, isEmpty);
    expect(
        await store.read(admission(
            digest: candidate.digest,
            length: candidate.length,
            user: '@other:test')),
        isNull);
    final file = File('${directory.path}/${candidate.digest}.cfsp');
    final bytes = await file.readAsBytes();
    expect(
        utf8.decode(bytes, allowMalformed: true), isNot(contains('"rooms"')));
    bytes[22] ^= 1;
    await file.writeAsBytes(bytes);
    expect(await store.read(accepted), isNull);
  });
  test('oversized envelope rejected before decode and installation is strict',
      () async {
    expect(
        await store.read(admission(
            digest: 'a' * 64, length: startupProjectionMaxEnvelope + 1)),
        isNull);
    await File('${directory.path}/installation').writeAsString('a' * 44);
    expect(await store.readInstallation(), isNull);
    expect(
        () => StartupProjection.decode(utf8
            .encode('{"version":1,"kind":"valid","rooms":[],"extra":true}')),
        throwsFormatException);
  });
  Future<(SecureSessionStore, _Secure, String)> secureFixture() async {
    final raw = _Secure();
    final secure = SecureSessionStore(raw);
    await secure.matrixDatabaseKey();
    await secure.registrationDeviceKey();
    await secure.saveSession(
        accessToken: 'synthetic',
        refreshToken: 'synthetic',
        matrixUserId: '@synthetic:test');
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: '@synthetic:test',
        deviceId: 'SYNTHETIC',
        homeserver: 'https://synthetic.test',
        databaseGeneration: 'synthetic-generation',
        ed25519Fingerprint: 'synthetic-fingerprint'));
    final install = await store.primeInstallation();
    final a = (await secure.prepareStartupProjectionHead(install))!;
    final file = await store.prepare(a, StartupProjection([]));
    expect(
        await secure.commitStartupProjectionHead(a, file.digest, file.length),
        isTrue);
    return (secure, raw, install);
  }

  test(
      'bounded secure admission is read only and rejects oversized identity records',
      () async {
    final (secure, raw, install) = await secureFixture();
    final before = raw.writes;
    expect(await secure.readStartupProjectionAdmission(install), isNotNull);
    expect(raw.writes, before);
    raw.values['liuhetong.matrix_account_slots.v1'] = ' ' * 65537;
    expect(await secure.readStartupProjectionAdmission(install), isNull);
    expect(raw.writes, before);
    raw.values.remove('liuhetong.matrix_account_slots.v1');
    raw.values['liuhetong.matrix_local_binding.v1'] = ' ' * 8193;
    expect(await secure.readStartupProjectionAdmission(install), isNull);
    expect(raw.writes, before);
  });
  test(
      'privacy request fence precedes request and survives crash, unrelated sync and relogin',
      () async {
    final (secure, raw, install) = await secureFixture();
    await secure.invalidateStartupProjection();
    await secure.fenceStartupProjectionPrivacy(
        roomId: '!synthetic:test', eventId: r'$target');
    // A request may have been accepted at this point even if its response is
    // lost. A fresh store/process must not prime the old local database.
    final reopened = SecureSessionStore(raw);
    expect(await reopened.prepareStartupProjectionHead(install), isNull);
    await reopened.clearBusinessSession();
    await reopened.saveSession(
        accessToken: 'new-synthetic',
        refreshToken: 'new-synthetic',
        matrixUserId: '@synthetic:test');
    await reopened.invalidateStartupProjection();
    await reopened
        .settleStartupProjectionPrivacy(leftRooms: {}, redactedEvents: {
      '!synthetic:test': {r'$other'}
    });
    expect(await reopened.prepareStartupProjectionHead(install), isNull);
    await reopened
        .settleStartupProjectionPrivacy(leftRooms: {}, redactedEvents: {
      '!synthetic:test': {r'$target'}
    });
    expect(await reopened.prepareStartupProjectionHead(install), isNotNull);
  });
  test(
      'unresolved privacy fence capacity never evicts targets to allow old cache',
      () async {
    final (secure, raw, install) = await secureFixture();
    for (var i = 0; i < 80; i++) {
      await secure.fenceStartupProjectionPrivacy(
          roomId: '!synthetic-$i:test', eventId: 'event-$i');
    }
    expect(
        utf8.encode(raw.values['liuhetong.startup_projection_head.v1']!).length,
        lessThanOrEqualTo(4096));
    await secure.invalidateStartupProjection();
    expect(await SecureSessionStore(raw).prepareStartupProjectionHead(install),
        isNull);
  });
  test('typed cached media retains kind and only allowlisted display metadata',
      () {
    for (final kind in [
      'm.text',
      'm.image',
      'm.video',
      'm.audio',
      'm.file',
      'm.sticker',
      'com.changliao.red_packet'
    ]) {
      final event = StartupProjectionEvent.fromJson({
        'id': 'synthetic-event',
        'sender': '@synthetic:test',
        'body': 'Synthetic display',
        'timestamp': 1,
        'senderName': 'Synthetic',
        'kind': kind,
        'media': {
          'mime': 'image/png',
          'width': 20,
          'height': 30,
          'size': 50,
          'duration': 100
        }
      });
      expect(event.toJson()['kind'], kind);
      expect((event.toJson()['media'] as Map).containsKey('key'), isFalse);
    }
    expect(
        () => StartupProjectionEvent.fromJson({
              'id': 'id',
              'sender': 'sender',
              'body': 'body',
              'timestamp': 1,
              'senderName': 'sender',
              'kind': 'm.image',
              'media': {'key': 'forbidden'}
            }),
        throwsFormatException);
  });
  test(
      'every binding dimension authenticates and an unpublished candidate preserves old head',
      () async {
    final first = await store.prepare(admission(), StartupProjection([]));
    final accepted = admission(digest: first.digest, length: first.length);
    for (final dimension in [
      'scope',
      'homeserver',
      'user',
      'device',
      'fingerprint',
      'generation',
      'installation',
      'epoch',
      'key'
    ]) {
      final changed = StartupProjectionAdmission(
          scope: dimension == 'scope' ? 'alternate' : accepted.scope,
          homeserver: dimension == 'homeserver'
              ? 'https://alternate.test'
              : accepted.homeserver,
          userId: dimension == 'user' ? '@alternate:test' : accepted.userId,
          deviceId: dimension == 'device' ? 'ALTERNATE' : accepted.deviceId,
          fingerprint:
              dimension == 'fingerprint' ? 'alternate' : accepted.fingerprint,
          databaseGeneration: dimension == 'generation'
              ? 'alternate'
              : accepted.databaseGeneration,
          installationId: dimension == 'installation'
              ? StartupProjectionStore.randomEpoch()
              : accepted.installationId,
          epoch: dimension == 'epoch'
              ? StartupProjectionStore.randomEpoch()
              : accepted.epoch,
          databaseKey: dimension == 'key'
              ? base64Url.encode(List.filled(32, 9))
              : accepted.databaseKey,
          registrationKey: accepted.registrationKey,
          digest: first.digest,
          length: first.length);
      expect(await store.read(changed), isNull, reason: dimension);
    }
    final candidate = await store.prepare(accepted, StartupProjection([]));
    expect(candidate.digest, isNot(first.digest));
    expect(await StartupProjectionStore(directory).read(accepted), isNotNull,
        reason:
            'crash before secure-head commit retains the old complete envelope');
    final files = await directory
        .list()
        .where((file) => file is File)
        .cast<File>()
        .toList();
    var bytes = 0;
    for (final file in files) {
      bytes += await file.length();
    }
    expect(bytes, lessThanOrEqualTo(4 * 1024 * 1024));
    await store.clean(first.digest);
    expect(await store.read(accepted), isNotNull);
  });
  test('unknown secure head fields fail closed without writes', () async {
    final (secure, raw, install) = await secureFixture();
    final head = jsonDecode(raw.values['liuhetong.startup_projection_head.v1']!)
        as Map<String, dynamic>;
    head['pending'] = 'malformed';
    raw.values['liuhetong.startup_projection_head.v1'] = jsonEncode(head);
    final before = raw.writes;
    expect(await secure.readStartupProjectionAdmission(install), isNull);
    expect(raw.writes, before);
  });
}
