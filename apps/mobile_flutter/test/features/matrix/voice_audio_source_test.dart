import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';

class _Player extends Fake implements AudioPlayer {
  final events = <String>[];
  AudioContext? context;
  bool failPlay = false;
  @override
  Source? source;

  @override
  Future<void> setAudioContext(AudioContext context) async {
    this.context = context;
    events.add('context');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }

  @override
  Future<void> resume() async {
    events.add('resume');
  }

  @override
  Future<void> play(Source source,
      {double? volume,
      double? balance,
      AudioContext? ctx,
      Duration? position,
      PlayerMode? mode}) async {
    this.source = source;
    events.add('play');
    if (failPlay) throw StateError('source failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Darwin playback owns a suffixed local file until stop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = Directory(
        '../../docs/verification/artifacts/2026-09-10/chat-reliability-2084/voice/source-fixture');
    await directory.create(recursive: true);
    final player = _Player();
    final bytes = Uint8List.fromList([0, 0, 0, 24, ...'ftypM4A '.codeUnits]);
    final engine = AudioplayersVoiceEngine(
        player: player, temporaryDirectory: () async => directory);
    await engine.play(bytes, earpiece: false);
    expect(player.source, isA<DeviceFileSource>());
    final source = player.source as DeviceFileSource;
    expect(source.path, endsWith('.m4a'));
    expect(await File(source.path).readAsBytes(), bytes);
    await engine.play(bytes, earpiece: false);
    final next = player.source as DeviceFileSource;
    expect(next.path, isNot(source.path));
    expect(await File(source.path).exists(), isFalse);
    await engine.stop();
    expect(await File(next.path).exists(), isFalse);
  });
  test('iOS prepares active audio session before play and every resume',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final player = _Player();
    const channel = MethodChannel('chatflow/voice_audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      player.events.add(call.method);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final directory = Directory(
        '../../docs/verification/artifacts/2026-09-10/chat-reliability-2084/voice/session-fixture');
    await directory.create(recursive: true);
    final engine = AudioplayersVoiceEngine(
        player: player, temporaryDirectory: () async => directory);
    await engine.play(Uint8List.fromList([1]), earpiece: false);
    await engine.resume();
    expect(
        player.events,
        containsAllInOrder([
          'checkPlaybackAllowed',
          'stop',
          'preparePlayback',
          'play',
          'checkPlaybackAllowed',
          'preparePlayback',
          'resume',
        ]));
    expect(player.context, isNull,
        reason: 'native call guard precedes session mutation');
    await engine.stop();
  });

  test('speaker selection sets the Android speaker route explicitly', () async {
    final player = _Player();
    await AudioplayersVoiceEngine(player: player)
        .play(Uint8List.fromList([1]), earpiece: false);
    expect(player.context!.android.isSpeakerphoneOn, isTrue);
  });

  test('iOS call ownership prevents playback before any player mutation',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('chatflow/voice_audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'VOICE_CALL_ACTIVE');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final player = _Player();
    await expectLater(
        AudioplayersVoiceEngine(player: player)
            .play(Uint8List.fromList([1]), earpiece: false),
        throwsA(isA<PlatformException>()));
    expect(player.events, isEmpty);
  });

  test('route switch preserves source and resume reapplies selected route',
      () async {
    final player = _Player();
    final engine = AudioplayersVoiceEngine(player: player);
    await engine.play(Uint8List.fromList([1]), earpiece: false);
    final source = player.source;
    await engine.setEarpiece(true);
    expect(player.context!.android.audioMode, AndroidAudioMode.inCommunication);
    expect(
        player.context!.android.usageType, AndroidUsageType.voiceCommunication);
    expect(player.source, same(source));
    await engine.resume();
    expect(player.context!.android.isSpeakerphoneOn, isFalse);
    await engine.setEarpiece(false);
    expect(player.context!.android.isSpeakerphoneOn, isTrue);
    expect(player.events.where((event) => event == 'play'), hasLength(1));
  });

  test('Darwin source failure releases the decrypted temporary file', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = Directory(
        '../../docs/verification/artifacts/2026-09-10/chat-reliability-2084/voice/failed-source-fixture');
    await directory.create(recursive: true);
    final player = _Player()..failPlay = true;
    final engine = AudioplayersVoiceEngine(
        player: player, temporaryDirectory: () async => directory);
    await expectLater(engine.play(Uint8List.fromList([1]), earpiece: false),
        throwsStateError);
    expect(await directory.list().toList(), isEmpty);
  });
  test('WAV container supplies MIME for extensionless Darwin playback',
      () async {
    final player = _Player();
    final bytes = Uint8List.fromList([
      ...'RIFF'.codeUnits,
      36,
      0,
      0,
      0,
      ...'WAVE'.codeUnits,
      ...'fmt '.codeUnits,
    ]);
    await AudioplayersVoiceEngine(player: player).play(bytes, earpiece: false);
    expect((player.source as BytesSource).mimeType, 'audio/wav');
    expect((player.source as BytesSource).bytes, same(bytes));
  });

  test('another RIFF container is not mislabeled as WAV', () async {
    final player = _Player();
    await AudioplayersVoiceEngine(player: player).play(
      Uint8List.fromList(
          [...'RIFF'.codeUnits, 36, 0, 0, 0, ...'AVI '.codeUnits]),
      earpiece: false,
    );
    expect((player.source as BytesSource).mimeType, isNull);
  });

  test('M4A recording supplies MP4 container MIME to extensionless playback',
      () async {
    final player = _Player();
    final bytes = Uint8List.fromList([
      0,
      0,
      0,
      24,
      ...'ftypM4A '.codeUnits,
      0,
      0,
      0,
      0,
      ...'M4A isom'.codeUnits,
    ]);
    await AudioplayersVoiceEngine(player: player).play(bytes, earpiece: false);
    expect((player.source as BytesSource).mimeType, 'audio/mp4');
    expect((player.source as BytesSource).bytes, same(bytes));
  });

  test('raw AAC retains its container rather than being declared MP4',
      () async {
    final player = _Player();
    await AudioplayersVoiceEngine(player: player).play(
        Uint8List.fromList([0xff, 0xf1, 0x50, 0x80, 0, 0xff, 0xfc]),
        earpiece: false);
    expect((player.source as BytesSource).mimeType, 'audio/aac');
  });

  test('unknown short input is not mislabeled as a recording', () async {
    final player = _Player();
    await AudioplayersVoiceEngine(player: player)
        .play(Uint8List.fromList([0]), earpiece: false);
    expect((player.source as BytesSource).mimeType, isNull);
  });
}
