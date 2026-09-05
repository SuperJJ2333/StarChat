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
  test('first tap downloads, plays and marks the message as playing', () async {
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

  test('pause freezes and resume continues from the paused position', () async {
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
    expect(controller.isPlaying('voice-1'), isFalse, reason: '播放自然结束后气泡应复位为空闲');
  });

  test('M02：A 慢 B 快——B 完成后 A 的迟到加载不得触发播放', () async {
    final loads = <String, Completer<Uint8List>>{};
    var playCalls = 0;
    final engine = FakeVoiceAudioEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (eventId) =>
          (loads[eventId] ??= Completer<Uint8List>()).future,
      engine: engine,
    );
    // A 先点（下载挂起）。
    unawaited(controller.toggle(_voice('voice-a')));
    // stopAll 后点 B（B 的下载先完成）。
    await controller.stopAll();
    unawaited(controller.toggle(_voice('voice-b')));
    await Future<void>.delayed(Duration.zero);
    loads['voice-b']!.complete(Uint8List.fromList([2]));
    await Future<void>.delayed(Duration.zero);
    // A 的下载此时才完成：不得触发 play。
    loads['voice-a']!.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying('voice-a'), isFalse, reason: '迟到的 A 不得回到播放态');
    expect(controller.isPlaying('voice-b'), isTrue, reason: 'B 保持播放');
  });

  test('M02：stopAll 后完成的下载不调用 play；dispose 后不更新状态', () async {
    final gate = Completer<Uint8List>();
    var playCalls = 0;
    final played = <String>[];
    final engine = _TaggingVoiceEngine(playCalls: () => playCalls++, played: played);
    final controller = VoicePlaybackController(
      loadAttachment: (_) => gate.future,
      engine: engine,
    );
    unawaited(controller.toggle(_voice('voice-x')));
    await Future<void>.delayed(Duration.zero);
    await controller.stopAll();
    gate.complete(Uint8List.fromList([9]));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(playCalls, 0, reason: 'stopAll 使在途任务失效，不得调用 play');
    expect(controller.isPlaying('voice-x'), isFalse);

    // dispose 后完成的新下载同样不得触发 play 或通知。
    var notified = false;
    controller.addListener(() => notified = true);
    controller.dispose();
    final gate2 = Completer<Uint8List>();
    final engine2 = _TaggingVoiceEngine(playCalls: () => playCalls++, played: played);
    final controller2 = VoicePlaybackController(
      loadAttachment: (_) => gate2.future,
      engine: engine2,
    );
    unawaited(controller2.toggle(_voice('voice-y')));
    await Future<void>.delayed(Duration.zero);
    controller2.dispose();
    gate2.complete(Uint8List.fromList([8]));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(playCalls, 0, reason: 'dispose 后完成不得触发 play');
    expect(notified, isFalse);
  });
}

final class _TaggingVoiceEngine implements VoiceAudioEngine {
  _TaggingVoiceEngine({required this.playCalls, required this.played});

  final void Function() playCalls;
  final List<String> played;

  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async {
    playCalls();
    played.add('play');
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  final completedController = StreamController<void>.broadcast();

  @override
  final positionController = StreamController<Duration>.broadcast();

  @override
  Stream<void> get completed => completedController.stream;

  @override
  Stream<Duration> get position => positionController.stream;
}
