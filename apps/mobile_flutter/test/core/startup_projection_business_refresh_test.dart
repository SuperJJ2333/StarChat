import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_coordinator.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_store.dart';

class _Memory implements SecureKeyValueStore {
  final data = <String, String>{};
  Future<void> Function(String)? afterRead;
  Future<void> Function(String, String)? beforeWrite, afterWrite;
  @override
  Future<String?> read(String key) async {
    final value = data[key];
    await afterRead?.call(key);
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call(key, value);
    data[key] = value;
    await afterWrite?.call(key, value);
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
}

String _token(int sequence) => 'e30.'
    '${base64Url.encode(utf8.encode(jsonEncode({
              'sub': 'synthetic-user',
              'family_id': 'synthetic-family',
              'device_id': 'synthetic-device',
              'sequence': sequence
            }))).replaceAll('=', '')}.signature';

void main() {
  test(
      'same-owner business refresh retains committed display during and after HTTP',
      () async {
    final root = Directory(
            '../../docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures')
        .absolute;
    await root.create(recursive: true);
    final directory = await root.createTemp('refresh-');
    final secure = SecureSessionStore(_Memory());
    await secure.matrixDatabaseKey();
    await secure.registrationDeviceKey();
    await secure.saveSession(
        accessToken: _token(1),
        refreshToken: 'old-refresh',
        matrixUserId: '@synthetic:test',
        deviceKey: 'installation');
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: '@synthetic:test',
        deviceId: 'SYNTHETIC',
        homeserver: 'https://synthetic.test',
        databaseGeneration: 'generation',
        ed25519Fingerprint: 'fingerprint'));
    final cache = StartupProjectionStore(directory);
    final installation = await cache.primeInstallation();
    final admission =
        (await secure.prepareStartupProjectionHead(installation))!;
    final candidate = await cache.prepare(admission, StartupProjection([]));
    expect(
        await secure.commitStartupProjectionHead(
            admission, candidate.digest, candidate.length),
        isTrue);
    final coordinator = StartupProjectionCoordinator(
        invalidateHead: secure.invalidateStartupProjection)
      ..markVerified();
    secure.startupProjectionCoordinator = coordinator;
    final displayPermit = coordinator.beginDisplayCapture()!;
    final entered = Completer<void>();
    final release = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.synthetic.test'),
        sessionStore: secure,
        client: MockClient((_) async {
          entered.complete();
          await release.future;
          return http.Response(
              jsonEncode(
                  {'access_token': _token(2), 'refresh_token': 'next-refresh'}),
              200);
        }));
    final refresh = api.refreshSession();
    try {
      await entered.future.timeout(const Duration(seconds: 3));
      expect((await secure.session())!.pendingRefreshOperation, isNotNull);
      expect(coordinator.isDisplayCurrent(displayPermit), isTrue,
          reason: 'same-owner pending persistence is not identity replacement');
      final pending = await secure.readStartupProjectionAdmission(installation);
      expect(pending, isNotNull);
      expect(await cache.read(pending!), isNotNull);
      expect(await secure.prepareStartupProjectionHead(installation), isNull);
      release.complete();
      await refresh;
      expect(coordinator.isDisplayCurrent(displayPermit), isTrue);
      final current = await secure.readStartupProjectionAdmission(installation);
      expect(current, isNotNull);
      expect(await cache.read(current!), isNotNull);
    } finally {
      if (!release.isCompleted) release.complete();
      await refresh;
      coordinator.retire();
      await directory.delete(recursive: true);
    }
  });
  _safetyTests();
}

const _sessionKey = 'liuhetong.business_session.v1';
StoredBusinessSession _pending(StoredBusinessSession value) =>
    StoredBusinessSession(
        version: 1,
        accessToken: value.accessToken,
        refreshToken: value.refreshToken,
        matrixUserId: value.matrixUserId,
        deviceKey: value.deviceKey,
        pendingRefreshOperation: SecureSessionStore.newRefreshOperation());

class _Seed {
  _Seed(this.raw, this.secure, this.cache, this.directory, this.installation,
      this.coordinator);
  final _Memory raw;
  final SecureSessionStore secure;
  final StartupProjectionStore cache;
  final Directory directory;
  final String installation;
  final StartupProjectionCoordinator coordinator;
  static Future<_Seed> create(
      {String device = 'installation', bool verified = true}) async {
    final raw = _Memory();
    final secure = SecureSessionStore(raw);
    await secure.matrixDatabaseKey();
    await secure.registrationDeviceKey();
    await secure.saveSession(
        accessToken: _token(1),
        refreshToken: 'old-refresh',
        matrixUserId: '@synthetic:test',
        deviceKey: device);
    await secure.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: '@synthetic:test',
        deviceId: 'SYNTHETIC',
        homeserver: 'https://synthetic.test',
        databaseGeneration: 'generation',
        ed25519Fingerprint: 'fingerprint'));
    final root = Directory(
            '../../docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures')
        .absolute;
    await root.create(recursive: true);
    final directory = await root.createTemp('refresh-safety-');
    final cache = StartupProjectionStore(directory);
    final installation = await cache.primeInstallation();
    final admission =
        (await secure.prepareStartupProjectionHead(installation))!;
    final candidate = await cache.prepare(admission, StartupProjection([]));
    expect(
        await secure.commitStartupProjectionHead(
            admission, candidate.digest, candidate.length),
        isTrue);
    final coordinator = StartupProjectionCoordinator(
        invalidateHead: secure.invalidateStartupProjection);
    if (verified) coordinator.markVerified();
    secure.startupProjectionCoordinator = coordinator;
    return _Seed(raw, secure, cache, directory, installation, coordinator);
  }

  BusinessApiClient api() => BusinessApiClient(
      baseUri: Uri.parse('https://business.synthetic.test'),
      sessionStore: secure,
      client: MockClient((_) async => http.Response(
          jsonEncode(
              {'access_token': _token(2), 'refresh_token': 'next-refresh'}),
          200)));
  Future<
      (
        StoredBusinessSession,
        StoredBusinessSession,
        BusinessRefreshWriteContext
      )> context() async {
    final old = (await secure.session())!;
    final target = _pending(old);
    final context = await secure.prepareSameOwnerRefreshWrite(old, target);
    expect(context, isNotNull);
    return (old, target, context!);
  }

  Future<void> close() async {
    raw.afterRead = null;
    raw.beforeWrite = null;
    raw.afterWrite = null;
    coordinator.retire();
    if (!identical(coordinator, secure.startupProjectionCoordinator)) {
      secure.startupProjectionCoordinator?.retire();
    }
    await directory.delete(recursive: true);
  }
}

void _safetyTests() {
  test('malformed owner fields never qualify for preserving refresh', () async {
    for (final mode in ['matrix', 'device_key', 'claim_whitespace']) {
      final f = await _Seed.create();
      try {
        final claims = {
          'sub': 'synthetic-user',
          'family_id': 'synthetic-family',
          'device_id': 'synthetic-device'
        };
        if (mode == 'claim_whitespace') claims['family_id'] = ' ';
        final token = mode == 'claim_whitespace'
            ? 'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature'
            : _token(1);
        await f.secure.saveSession(
            accessToken: token,
            refreshToken: 'old-refresh',
            matrixUserId: mode == 'matrix' ? '@:' : '@synthetic:test',
            deviceKey:
                mode == 'device_key' ? ' installation ' : 'installation');
        final old = (await f.secure.session())!;
        expect(await f.secure.prepareSameOwnerRefreshWrite(old, _pending(old)),
            isNull,
            reason: mode);
      } finally {
        await f.close();
      }
    }
  });

  for (final field in ['sub', 'family_id', 'device_id', 'opaque']) {
    test('completed refresh cannot preserve changed $field lineage', () async {
      final f = await _Seed.create();
      try {
        final (_, pending, context) = await f.context();
        await context.persist();
        final claims = {
          'sub': 'synthetic-user',
          'family_id': 'synthetic-family',
          'device_id': 'synthetic-device'
        };
        if (field != 'opaque') claims[field] = 'other';
        final token = field == 'opaque'
            ? 'opaque'
            : 'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature';
        final target = StoredBusinessSession(
            version: 1,
            accessToken: token,
            refreshToken: 'next-refresh',
            matrixUserId: pending.matrixUserId,
            deviceKey: pending.deviceKey);
        expect(await f.secure.prepareSameOwnerRefreshWrite(pending, target),
            isNull);
      } finally {
        await f.close();
      }
    });
  }

  test('same-owner refresh cannot mark an unverified coordinator verified',
      () async {
    final f = await _Seed.create(verified: false);
    try {
      await f.api().refreshSession();
      expect(f.coordinator.canCapture, isFalse);
      expect(f.coordinator.beginCapture(), isNull);
      expect(await f.secure.readStartupProjectionAdmission(f.installation),
          isNotNull);
    } finally {
      await f.close();
    }
  });

  test('context is single use and readback before a write is closed', () async {
    final f = await _Seed.create();
    try {
      final (_, _, context) = await f.context();
      expect(() => context.targetIsPersisted(),
          throwsA(isA<BusinessRefreshWriteOwnerChanged>()));
      await context.persist();
      expect(await context.targetIsPersisted(), isTrue);
      expect(() => context.persist(),
          throwsA(isA<BusinessRefreshWriteOwnerChanged>()));
    } finally {
      await f.close();
    }
  });

  for (final mutation in [
    'clear',
    'bind',
    'key',
    'scope',
    'generic',
    'coordinator'
  ]) {
    test('established refresh context closes on $mutation', () async {
      final f = await _Seed.create();
      Future<void>? changing;
      try {
        final (old, target, context) = await f.context();
        switch (mutation) {
          case 'clear':
            changing = f.secure.clearBusinessSession();
          case 'bind':
            changing =
                f.secure.saveMatrixBinding((await f.secure.matrixBinding())!);
          case 'key':
            changing = f.secure.clearMatrixDatabaseKey();
          case 'scope':
            changing = f.secure
                .selectMatrixAccount('https://synthetic.test', '@other:test');
          case 'generic':
            changing = f.secure.saveSession(
                accessToken: target.accessToken,
                refreshToken: target.refreshToken,
                matrixUserId: target.matrixUserId,
                deviceKey: target.deviceKey,
                pendingRefreshOperation: target.pendingRefreshOperation);
          case 'coordinator':
            f.secure.startupProjectionCoordinator =
                StartupProjectionCoordinator(
                    invalidateHead: f.secure.invalidateStartupProjection);
        }
        expect(context.isCurrent, isFalse);
        await expectLater(Future<void>.sync(context.persist),
            throwsA(isA<BusinessRefreshWriteOwnerChanged>()));
        await changing;
        expect((await f.secure.session())?.accessToken,
            mutation == 'clear' ? isNull : old.accessToken);
      } finally {
        await changing;
        await f.close();
      }
    });
  }

  test(
      'CAS target already present is a closed failure, never readback recovery',
      () async {
    final f = await _Seed.create();
    try {
      final (_, target, context) = await f.context();
      final data = jsonDecode(f.raw.data[_sessionKey]!) as Map<String, dynamic>;
      data['pending_refresh_operation'] = target.pendingRefreshOperation;
      f.raw.data[_sessionKey] = jsonEncode(data);
      await expectLater(
          context.persist(), throwsA(isA<BusinessRefreshWriteOwnerChanged>()));
    } finally {
      await f.close();
    }
  });

  for (final malformed in ['numeric_device', 'unknown_field']) {
    test('raw $malformed cannot enter the preserving context', () async {
      final f = await _Seed.create(device: '123');
      try {
        final data =
            jsonDecode(f.raw.data[_sessionKey]!) as Map<String, dynamic>;
        if (malformed == 'numeric_device') data['device_key'] = 123;
        if (malformed == 'unknown_field') data['unknown'] = true;
        f.raw.data[_sessionKey] = jsonEncode(data);
        final old = (await f.secure.session())!;
        expect(await f.secure.prepareSameOwnerRefreshWrite(old, _pending(old)),
            isNull);
        await f.api().refreshSession();
        expect(f.coordinator.displayRevoked, isTrue,
            reason: 'legacy fallback retains full fence');
      } finally {
        await f.close();
      }
    });
  }

  for (final mode in [
    'opaque',
    'subject',
    'family',
    'device',
    'matrix',
    'device_key',
    'pending'
  ]) {
    test('unsupported $mode transition keeps generic fence', () async {
      final f = await _Seed.create();
      try {
        final old = (await f.secure.session())!;
        final claims = {
          'sub': 'synthetic-user',
          'family_id': 'synthetic-family',
          'device_id': 'synthetic-device'
        };
        if (mode == 'subject') claims['sub'] = 'other';
        if (mode == 'family') claims['family_id'] = 'other';
        if (mode == 'device') claims['device_id'] = 'other';
        final encoded =
            'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature';
        final target = StoredBusinessSession(
            version: 1,
            accessToken: mode == 'opaque'
                ? 'opaque'
                : mode == 'pending' || mode == 'matrix' || mode == 'device_key'
                    ? old.accessToken
                    : encoded,
            refreshToken: old.refreshToken,
            matrixUserId: mode == 'matrix' ? '@other:test' : old.matrixUserId,
            deviceKey: mode == 'device_key' ? 'other' : old.deviceKey,
            pendingRefreshOperation: mode == 'pending'
                ? 'malformed'
                : SecureSessionStore.newRefreshOperation());
        expect(
            await f.secure.prepareSameOwnerRefreshWrite(old, target), isNull);
        await f.secure.saveSession(
            accessToken: target.accessToken,
            refreshToken: target.refreshToken,
            matrixUserId: target.matrixUserId,
            deviceKey: target.deviceKey,
            pendingRefreshOperation: target.pendingRefreshOperation);
        expect(f.coordinator.displayRevoked, isTrue);
      } finally {
        await f.close();
      }
    });
  }

  for (final phase in ['pending', 'result']) {
    for (final after in [false, true]) {
      test('$phase storage failure afterCommit=$after has guarded outcome',
          () async {
        final f = await _Seed.create();
        try {
          Future<void> fault(String key, String value) async {
            if (key != _sessionKey) return;
            final data = jsonDecode(value) as Map;
            final matches = phase == 'pending'
                ? data['pending_refresh_operation'] != null
                : data['refresh_token'] == 'next-refresh';
            if (!matches) return;
            f.raw.beforeWrite = null;
            f.raw.afterWrite = null;
            throw PlatformException(code: 'synthetic-write-failure');
          }

          if (after) {
            f.raw.afterWrite = fault;
          } else {
            f.raw.beforeWrite = fault;
          }
          if (after) {
            expect(
                (await f.api().refreshSession()).refreshToken, 'next-refresh');
          } else {
            await expectLater(
                f.api().refreshSession(),
                throwsA(isA<BusinessApiException>().having(
                    (e) => e.code, 'code', 'SESSION_STORAGE_UNAVAILABLE')));
          }
          expect(await f.secure.readStartupProjectionAdmission(f.installation),
              isNotNull);
          expect(f.coordinator.displayRevoked, isFalse);
        } finally {
          await f.close();
        }
      });
    }
  }

  for (final revoke in [
    'generic_same_target',
    'clear',
    'coordinator',
    'readback_coordinator',
    'readback_failure'
  ]) {
    test('API cannot accept uncertain target after $revoke', () async {
      final f = await _Seed.create();
      Future<void>? changing;
      try {
        f.raw.afterWrite = (key, value) async {
          if (key != _sessionKey) return;
          final data = jsonDecode(value) as Map;
          if (data['refresh_token'] != 'next-refresh') return;
          f.raw.afterWrite = null;
          if (revoke == 'generic_same_target') {
            changing = f.secure.saveSession(
                accessToken: data['access_token'] as String,
                refreshToken: data['refresh_token'] as String,
                matrixUserId: data['matrix_user_id'] as String,
                deviceKey: data['device_key'] as String);
          } else if (revoke == 'clear') {
            changing = f.secure.clearBusinessSession();
          } else if (revoke == 'coordinator') {
            f.secure.startupProjectionCoordinator =
                StartupProjectionCoordinator(
                    invalidateHead: f.secure.invalidateStartupProjection);
          } else {
            f.raw.afterRead = (key) async {
              if (key != _sessionKey) return;
              f.raw.afterRead = null;
              if (revoke == 'readback_failure') {
                throw PlatformException(code: 'synthetic-read-failure');
              }
              f.secure.startupProjectionCoordinator =
                  StartupProjectionCoordinator(
                      invalidateHead: f.secure.invalidateStartupProjection);
            };
          }
          throw PlatformException(code: 'synthetic-after-write');
        };
        await expectLater(
            f.api().refreshSession(),
            throwsA(isA<BusinessApiException>().having(
                (e) => e.code,
                'code',
                revoke == 'readback_failure'
                    ? 'SESSION_STORAGE_UNAVAILABLE'
                    : 'AUTH_SESSION_ENDED')));
        await changing;
      } finally {
        await changing;
        await f.close();
      }
    });
  }
}
