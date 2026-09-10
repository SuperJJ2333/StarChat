import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:video_player/video_player.dart';
import 'package:video_compress/video_compress.dart';

// Fixtures contain only generated, four-second media in assets/diagnostics/.
// Run seed, terminate the app process, then run verify on the same simulator
// without uninstalling the app or clearing its container/Keychain.
const _phase = String.fromEnvironment('COMPAT_PHASE');
const _databaseKey = 'liuhetong.matrix_database_key.v1';
const _sessionKey = 'liuhetong.business_session.v1';
const _wait = Duration(seconds: 15);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 2));

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

  testWidgets(
      'account scoped native keys survive switching and restart ($_phase)',
      (_) async {
    final storage = FlutterSecureKeyValueStore();
    final sessions = SecureSessionStore(storage);
    final marker = File(p.join(
        (await getApplicationSupportDirectory()).path, 'account_scopes.json'));
    final Map<String, dynamic> expected;
    if (_phase == 'seed') {
      expect(await marker.exists(), isFalse);
      expected = {};
    } else {
      expect(await marker.exists(), isTrue);
      expected =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      // Prove native persistence before any API that could recreate missing keys.
      expect(await storage.read('liuhetong.active_matrix_scope.v1'),
          expected['aScope']);
      expect(
          await storage.read('liuhetong.matrix_account_slots.v1'), isNotNull);
      for (final account in ['a', 'b']) {
        final scope = expected['${account}Scope'] as String;
        final key = await storage.read('$_databaseKey.$scope');
        expect(key != null && key.isNotEmpty, isTrue);
        expect(
            sha256.convert(utf8.encode(key!)).toString() ==
                expected['${account}Digest'],
            isTrue);
      }
    }
    for (final account in ['a', 'b', 'a']) {
      await sessions.selectMatrixAccount(
          'https://synthetic.example.test', '@$account:synthetic.example.test');
      final scope = await sessions.matrixStorageScope();
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(scope), isTrue);
      final key = await sessions.matrixDatabaseKey();
      final digest = sha256.convert(utf8.encode(key)).toString();
      if (expected.containsKey('${account}Scope')) {
        expect(scope, expected['${account}Scope']);
        expect(digest == expected['${account}Digest'], isTrue);
      } else {
        expected['${account}Scope'] = scope;
        expected['${account}Digest'] = digest;
      }
    }
    expect(expected['aScope'] == expected['bScope'], isFalse);
    expect(expected['aDigest'] == expected['bDigest'], isFalse);
    if (_phase == 'seed') {
      await marker.writeAsString(jsonEncode(expected), flush: true);
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
        await player.dispose().timeout(_wait);
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
          final resumedAt =
              (await player.getCurrentPosition()) ?? Duration.zero;
          await _until(() async =>
              ((await player.getCurrentPosition()) ?? Duration.zero) >
              resumedAt + const Duration(milliseconds: 200));
          await engine.setEarpiece(!earpiece);
          await engine.stop();
          await engine.play(await _fixture(fixture.key), earpiece: earpiece);
          await _expectAudioAdvances(player);
          await engine.stop();
        } finally {
          await engine.dispose().timeout(_wait);
        }
      });
    }
  }
  for (final name in ['video-h264.mp4', 'video-hevc.mp4']) {
    for (final profile in [
      ChatVideoProfile.normal,
      ChatVideoProfile.aggressive(4000)
    ]) {
      testWidgets(
          'native reader/writer compresses $name at ${profile.maxDimension}',
          (_) async {
        final folder =
            await (await getTemporaryDirectory()).createTemp('encoder-');
        final source = File(p.join(folder.path, name));
        File? output;
        VideoPlayerController? player;
        try {
          await source.writeAsBytes(await _fixture(name), flush: true);
          final result = await VideoCompress.compressVideo(source.path,
                  quality: VideoQuality.Res640x480Quality,
                  deleteOrigin: false,
                  includeAudio: true,
                  frameRate: profile.frameRate,
                  maxDimension: profile.maxDimension,
                  videoBitrate: profile.videoBitrate,
                  audioBitrate: profile.audioBitrate,
                  audioSampleRate: profile.audioSampleRate,
                  audioChannels: 1)
              .timeout(const Duration(seconds: 60));
          expect(result?.isCancel, isNot(true));
          output = result?.file;
          expect(output, isNotNull);
          expect(output!.absolute.path == source.absolute.path, isFalse);
          expect(await source.exists(), isTrue);
          expect(await output.length(),
              inInclusiveRange(1, maxOriginalVideoBytes));
          player = VideoPlayerController.file(output);
          await player.initialize().timeout(_wait);
          expect(player.value.duration.inMilliseconds,
              inInclusiveRange(3500, 4500));
          expect(player.value.size.longestSide,
              lessThanOrEqualTo(profile.maxDimension));
          expect(player.value.size.shortestSide, greaterThan(0));
          await player.play();
          final activePlayer = player;
          await _until(() async {
            expect(activePlayer.value.hasError, isFalse);
            return ((await activePlayer.position)?.inMilliseconds ?? 0) >= 300;
          });
        } finally {
          await player?.dispose();
          if (output != null &&
              output.path != source.path &&
              await output.exists()) {
            await output.delete();
          }
          await folder.delete(recursive: true);
        }
      });
    }
    for (final extensionless in [false, true]) {
      testWidgets(
          'native VideoPlayer $name '
          '${extensionless ? 'production cache resolver' : 'mp4 file'} advances',
          (_) async {
        final bytes = await _fixture(name);
        late File file;
        if (extensionless) {
          final key = MediaCacheKey(
            roomId: '!synthetic-compat:example.test',
            eventId: sha256.convert(utf8.encode('synthetic-$name')).toString(),
          );
          await MediaCache.store(key.roomId, key.eventId, bytes);
          file = await resolveCachedVideoFile(
            key: key,
            decrypt: () async =>
                throw StateError('Cached media must not download'),
          );
          expect(file.path.endsWith('.mp4'), isTrue);
          expect(await file.length(), bytes.length);
        } else {
          file = File(p.join((await getTemporaryDirectory()).path, name));
          await file.writeAsBytes(bytes, flush: true);
        }
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
          await player.dispose().timeout(_wait);
          await file.delete();
          final meta = File('${file.path}.len');
          if (await meta.exists()) await meta.delete();
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
