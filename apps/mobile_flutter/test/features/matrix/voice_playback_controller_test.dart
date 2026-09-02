import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';

final class FakeVoiceAudioEngine implements VoiceAudioEngine {
  final played = <bool>[];
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  final completedController = StreamController<void>.broadcast();
  final positionController = StreamController<Duration>.broadcast();

  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async {
    played.add(earpiece);
  }

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> resume() async => resumeCalls++;

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Stream<void> get completed => completedController.stream;

  @override
  Stream<Duration> get position => positionController.stream;

  void finishNaturally() => completedController.add(null);

  void emitPosition(Duration position) => positionController.add(position);
}

RoomMessageViewModel _voice(String id) => RoomMessageViewModel(
      id: id,
      senderId: '@peer:test',
      text: '',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime(2026),
      kind: RoomMessageKind.voice,
      voiceDuration: const Duration(seconds: 6),
    );

void main() {
  test('first tap downloads, plays and marks the message as playing',
      () async {
    final engine = FakeVoiceAudioEngine();
    final downloads = <String>[];
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async {
        downloads.add(eventId);
        return Uint8List.fromList([1, 2, 3]);
      },
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));

    expect(downloads, ['voice-1']);
    expect(engine.played, [false]); // 默认扬声器播放。
    expect(controller.isPlaying('voice-1'), isTrue);
  });

  test('second tap on a playing message pauses it', () async {
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async => Uint8List.fromList([1]),
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));
    await controller.toggle(_voice('voice-1'));

    expect(engine.pauseCalls, 1, reason: '播放中点击 = 暂停（高亮定格）');
    expect(engine.stopCalls, 0);
    expect(controller.isPaused('voice-1'), isTrue);
    expect(controller.isPlaying('voice-1'), isFalse);
  });

  test('repeat play of a cached message does not re-download', () async {
    final engine = FakeVoiceAudioEngine();
    final disk = <String, Uint8List>{};
    final downloads = <String>[];
    final controller = VoicePlaybackController(
      // 模拟 RoomPage 的 MediaCache 包装：磁盘命中则不触发网络解密下载。
      loadAttachment: (eventId) async {
        final cached = disk[eventId];
        if (cached != null) return cached;
        downloads.add(eventId);
        final bytes = Uint8List.fromList([1]);
        disk[eventId] = bytes;
        return bytes;
      },
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));
    await controller.toggle(_voice('voice-1'));
    await controller.toggle(_voice('voice-1'));
    await controller.toggle(_voice('voice-1'));
    await controller.toggle(_voice('voice-1'));

    expect(downloads, hasLength(1), reason: '缓存命中后不再重复下载');
    expect(engine.played, hasLength(1), reason: '暂停/继续不重新播放');
    expect(engine.pauseCalls, 2);
    expect(engine.resumeCalls, 2);
  });

  test('starting another voice stops the previous one', () async {
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async => Uint8List.fromList([1]),
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));
    await controller.toggle(_voice('voice-2'));

    expect(controller.isPlaying('voice-1'), isFalse);
    expect(controller.isPlaying('voice-2'), isTrue);
  });

  test('earpiece toggle is forwarded to the audio engine', () async {
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async => Uint8List.fromList([1]),
      engine: engine,
    );

    controller.earpiece = true;
    await controller.toggle(_voice('voice-1'));

    expect(engine.played.single, isTrue);
  });

  test('pause freezes and resume continues from the paused position',
      () async {
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async => Uint8List.fromList([1]),
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));
    expect(controller.isPlaying('voice-1'), isTrue);

    // 播放中点击 → 暂停（高亮定格）。
    await controller.toggle(_voice('voice-1'));
    expect(engine.pauseCalls, 1);
    expect(controller.isPaused('voice-1'), isTrue);
    expect(controller.isPlaying('voice-1'), isFalse);

    // 暂停中点击 → 从暂停位置继续（不重头）。
    await controller.toggle(_voice('voice-1'));
    expect(engine.resumeCalls, 1);
    expect(controller.isPlaying('voice-1'), isTrue);
    expect(engine.stopCalls, 0, reason: '暂停/继续不应 stop 重播');
  });

  test('playback position updates feed the sweep progress', () async {
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async => Uint8List.fromList([1]),
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));
    expect(controller.positionOf('voice-1'), isNull);

    engine.emitPosition(const Duration(milliseconds: 2500));
    await Future<void>.delayed(Duration.zero);
    expect(controller.positionOf('voice-1'), const Duration(milliseconds: 2500),
        reason: '真实播放位置驱动扫过进度');
  });

  test('playback finishing naturally resets the playing state', () async {
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) async => Uint8List.fromList([1]),
      engine: engine,
    );

    await controller.toggle(_voice('voice-1'));
    expect(controller.isPlaying('voice-1'), isTrue);

    engine.finishNaturally();
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying('voice-1'), isFalse,
        reason: '播放自然结束后气泡应复位为空闲');
  });
}
