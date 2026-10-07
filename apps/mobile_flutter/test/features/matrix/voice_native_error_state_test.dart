import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';

class _Engine implements VoiceAudioEngine {
  final completions = StreamController<void>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  int plays = 0;
  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async => plays++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<void> get completed => completions.stream;
  @override
  Stream<Duration> get position => positions.stream;
}

RoomMessageViewModel _voice(String id) => RoomMessageViewModel(
      id: id,
      senderId: '@synthetic:example.test',
      text: '',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.utc(2026, 10, 7),
      kind: RoomMessageKind.voice,
      voiceDuration: const Duration(seconds: 1),
    );

void main() {
  for (final paused in [false, true]) {
    test('native error while ${paused ? 'paused' : 'playing'} preserves retry',
        () async {
      final engine = _Engine();
      var nextRequested = 0;
      final playback = VoicePlaybackController(
        loadAttachment: (_) async => Uint8List.fromList([1]),
        engine: engine,
        autoPlayNextVoiceEnabled: () => true,
        nextAutoPlayVoice: (_) {
          nextRequested++;
          return _voice('next');
        },
      );
      addTearDown(() async {
        playback.dispose();
        await engine.completions.close();
        await engine.positions.close();
      });
      await playback.toggle(_voice('current'));
      if (paused) await playback.toggle(_voice('current'));
      engine.completions.addError(StateError('synthetic native error'));
      await Future<void>.delayed(Duration.zero);
      expect(playback.isPlayed('current'), isFalse);
      expect(nextRequested, 0);
      expect(playback.hasFailed('current'), isTrue);
      expect(playback.playingIds, isEmpty);
      expect(playback.isPaused('current'), isFalse);
      expect(playback.positionOf('current'), isNull);
      engine.completions.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(playback.hasFailed('current'), isTrue);
      expect(playback.isPlayed('current'), isFalse);
      expect(nextRequested, 0);
      await playback.toggle(_voice('current'));
      expect(playback.hasFailed('current'), isFalse);
      expect(playback.isPlaying('current'), isTrue);
      expect(engine.plays, 2);
    });
  }

  test('natural completion still marks heard and advances once', () async {
    final engine = _Engine();
    var nextRequested = 0;
    final playback = VoicePlaybackController(
      loadAttachment: (_) async => Uint8List.fromList([1]),
      engine: engine,
      nextAutoPlayVoice: (_) {
        nextRequested++;
        return _voice('next');
      },
    );
    addTearDown(() async {
      playback.dispose();
      await engine.completions.close();
      await engine.positions.close();
    });
    await playback.toggle(_voice('current'));
    engine.completions.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(playback.isPlayed('current'), isTrue);
    expect(nextRequested, 1);
    expect(playback.isPlaying('next'), isTrue);
    expect(engine.plays, 2);
  });
}
