import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';

class _Player extends Fake implements AudioPlayer {
  @override
  Source? source;

  @override
  Future<void> setAudioContext(AudioContext context) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> play(Source source,
      {double? volume,
      double? balance,
      AudioContext? ctx,
      Duration? position,
      PlayerMode? mode}) async {
    this.source = source;
  }
}

void main() {
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
