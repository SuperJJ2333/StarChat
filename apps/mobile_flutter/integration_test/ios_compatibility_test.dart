import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:video_player/video_player.dart';

// CI creates only synthetic, four-second media in assets/diagnostics/.
// Run seed, terminate the app process, then run verify on the same simulator
// without uninstalling the app or clearing its container/Keychain.
const _phase = String.fromEnvironment('COMPAT_PHASE');
const _databaseKey = 'liuhetong.matrix_database_key.v1';
const _sessionKey = 'liuhetong.business_session.v1';
const _wait = Duration(seconds: 15);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('diagnostic invocation is explicitly iOS seed or verify',
      (_) async {
    expect(Platform.isIOS, isTrue,
        reason: 'Requires real iOS plugin bindings.');
    expect(_phase, anyOf('seed', 'verify'));
  });

  if (_phase != 'seed' && _phase != 'verify') return;

  testWidgets('Keychain and SQLCipher survive process restart ($_phase)',
      (_) async {
    final storage = FlutterSecureKeyValueStore();
    final sessions = SecureSessionStore(storage);
    final path = p.join(
      (await getApplicationSupportDirectory()).path,
      'ios_compatibility.sqlite',
    );
    final existingKey = await storage.read(_databaseKey);
    if (_phase == 'verify') {
      // Never call a create-on-missing getter before proving retention.
      expect(existingKey != null && existingKey.isNotEmpty, isTrue,
          reason: 'Seeded native Keychain database key must still exist.');
      expect(await storage.read(_sessionKey) != null, isTrue,
          reason: 'Seeded native business session must still exist.');
      expect(await File(path).exists(), isTrue,
          reason:
              'Seeded SQLCipher database must survive process termination.');
    } else {
      expect(await File(path).exists(), isFalse,
          reason: 'Seed requires a fresh diagnostic simulator container.');
      await sessions.saveSession(
        accessToken: 'synthetic-compat-access',
        refreshToken: 'synthetic-compat-refresh',
      );
    }
    final cipher =
        _phase == 'verify' ? existingKey! : await sessions.matrixDatabaseKey();
    final digest = sha256.convert(utf8.encode(cipher)).toString();
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: factory,
      path: path,
      cipher: cipher,
    );
    // Do not migrate or recreate anything in the verification phase.
    if (_phase == 'seed') await encryption.ensureDatabaseFileEncrypted();
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey),
    );
    try {
      expect(await database.rawQuery('PRAGMA cipher_version'), isNotEmpty);
      if (_phase == 'seed') {
        await database.transaction((transaction) async {
          await transaction.execute(
            'CREATE TABLE compatibility_probe '
            '(id INTEGER PRIMARY KEY, phase TEXT NOT NULL, '
            'key_digest TEXT NOT NULL, payload TEXT NOT NULL)',
          );
          await transaction.insert('compatibility_probe', {
            'id': 1,
            'phase': 'seed',
            'key_digest': digest,
            'payload': 'synthetic-history-row',
          });
        });
      }
      final rows = await database.query('compatibility_probe');
      expect(rows.length, 1);
      expect(rows.single['phase'], 'seed');
      expect(rows.single['payload'], 'synthetic-history-row');
      // Compare booleans to keep key material and its digest out of failures.
      expect(rows.single['key_digest'] == digest, isTrue,
          reason: 'Persisted database must use the original Keychain key.');
      final session = await sessions.session();
      expect(session?.accessToken == 'synthetic-compat-access', isTrue);
      expect(session?.refreshToken == 'synthetic-compat-refresh', isTrue);
    } finally {
      await database.close();
    }
    final file = await File(path).open();
    try {
      final header = await file.read(16);
      expect(header.length, 16);
      expect(
          ascii.decode(header, allowInvalid: true) == 'SQLite format 3\u0000',
          isFalse,
          reason: 'Diagnostic database must be encrypted on disk.');
    } finally {
      await file.close();
    }
  });

  // Media coverage runs once; verify concentrates on cross-process retention.
  if (_phase != 'seed') return;
  for (final fixture in <String, String>{
    'tone.m4a': 'audio/mp4',
    'tone.aac': 'audio/aac',
    'tone.wav': 'audio/wav',
  }.entries) {
    testWidgets('native AudioPlayer decodes and advances ${fixture.key}',
        (_) async {
      final bytes = await _fixture(fixture.key);
      final player = AudioPlayer();
      try {
        await player.setAudioContext(AudioContextConfig(
          route: AudioContextConfigRoute.system,
          respectSilence: false,
        ).build());
        await player
            .play(BytesSource(bytes, mimeType: fixture.value))
            .timeout(_wait);
        await _expectAudioAdvances(player);
      } finally {
        await player.dispose();
      }
    });
    for (final earpiece in [false, true]) {
      testWidgets(
          'production voice engine ${fixture.key} '
          '${earpiece ? 'earpiece' : 'system'} initializes and advances',
          (_) async {
        final player = AudioPlayer();
        final engine = AudioplayersVoiceEngine(player: player);
        try {
          await engine
              .play(await _fixture(fixture.key), earpiece: earpiece)
              .timeout(_wait);
          await _expectAudioAdvances(player);
          await engine.pause();
          expect(player.state, PlayerState.paused);
          await engine.resume();
          await engine.stop();
        } finally {
          await player.dispose();
        }
      });
    }
  }
  for (final name in ['video-h264.mp4', 'video-hevc.mp4']) {
    for (final extensionless in [false, true]) {
      testWidgets(
          'native VideoPlayer $name '
          '${extensionless ? 'extensionless cache' : 'mp4 file'} advances',
          (_) async {
        // MediaCache uses opaque extensionless names in production. Exercise
        // those separately from normal .mp4 files to expose type sniffing bugs.
        final cacheName = extensionless
            ? sha256.convert(utf8.encode('synthetic-$name')).toString()
            : name;
        final file =
            File(p.join((await getTemporaryDirectory()).path, cacheName));
        await file.writeAsBytes(await _fixture(name), flush: true);
        final player = VideoPlayerController.file(file);
        try {
          await player.initialize().timeout(_wait);
          expect(player.value.isInitialized, isTrue);
          expect(player.value.duration.inMilliseconds, greaterThan(1000));
          expect(player.value.size.width, greaterThan(0));
          expect(player.value.size.height, greaterThan(0));
          await player.play().timeout(_wait);
          await _until(() async {
            expect(player.value.hasError, isFalse,
                reason: player.value.errorDescription);
            final position = await player.position;
            return (position?.inMilliseconds ?? 0) >= 300;
          });
        } finally {
          await player.dispose();
          await file.delete();
        }
      });
    }
  }
}

Future<Uint8List> _fixture(String name) async {
  final data = await rootBundle.load('assets/diagnostics/$name');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<void> _expectAudioAdvances(AudioPlayer player) async {
  await _until(
      () async => ((await player.getDuration())?.inMilliseconds ?? 0) > 1000);
  await _until(() async =>
      ((await player.getCurrentPosition())?.inMilliseconds ?? 0) >= 300);
}

Future<void> _until(Future<bool> Function() condition) async {
  final watch = Stopwatch()..start();
  while (!await condition().timeout(_wait)) {
    if (watch.elapsed >= _wait) {
      fail('Native player did not expose expected duration or progression.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
