import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';

final class _FakeEngine implements VoiceAudioEngine {
  final played = <String>[];
  final completedController = StreamController<void>.broadcast();
  final positionController = StreamController<Duration>.broadcast();

  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async {
    played.add('play');
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<void> get completed => completedController.stream;
  @override
  Stream<Duration> get position => positionController.stream;

  void finishNaturally() => completedController.add(null);
}

RoomMessageViewModel _voice(String id) => RoomMessageViewModel(
      id: id,
      senderId: '@peer:test',
      text: '',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime(2026),
      kind: RoomMessageKind.voice,
      voiceDuration: const Duration(seconds: 5),
    );

void main() {
  test('BUG-40：自然播完后自动连播同会话下一条未读语音（默认开启）', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (_) async => Uint8List.fromList([1]),
      engine: engine,
      nextAutoPlayVoice: (current) => current == 'a' ? _voice('b') : null,
    );

    await controller.toggle(_voice('a'));
    engine.finishNaturally();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isPlayed('a'), isTrue, reason: '播完即记为已播');
    expect(controller.isPlaying('b'), isTrue, reason: '读完自动播下一条未读语音');
    controller.dispose();
  });

  test('BUG-40：设置关闭时播完即停（行为与旧版一致）', () async {
    final engine = _FakeEngine();
    var enabled = false;
    final controller = VoicePlaybackController(
      loadAttachment: (_) async => Uint8List.fromList([1]),
      engine: engine,
      autoPlayNextVoiceEnabled: () => enabled,
      nextAutoPlayVoice: (current) => current == 'a' ? _voice('b') : null,
    );

    await controller.toggle(_voice('a'));
    engine.finishNaturally();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isPlaying('b'), isFalse, reason: '开关关闭时绝不连播');
    controller.dispose();
  });

  test('BUG-40：没有下一条未读语音时播完即停', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (_) async => Uint8List.fromList([1]),
      engine: engine,
      nextAutoPlayVoice: (current) => null,
    );

    await controller.toggle(_voice('a'));
    engine.finishNaturally();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isPlaying('a'), isFalse);
    expect(engine.played, hasLength(1), reason: '不重复播放任何语音');
    controller.dispose();
  });

  test('BUG-40：用户手动暂停不触发连播', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (_) async => Uint8List.fromList([1]),
      engine: engine,
      nextAutoPlayVoice: (current) => _voice('b'),
    );

    await controller.toggle(_voice('a'));
    await controller.toggle(_voice('a')); // 暂停
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPaused('a'), isTrue);

    engine.completedController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.isPlaying('b'), isFalse,
        reason: '只有自然播完才连播，暂停（高亮定格）后等待用户继续');
    controller.dispose();
  });

  test('BUG-40：连播的下一条下载失败不级联、停留在可重试态', () async {
    final engine = _FakeEngine();
    final controller = VoicePlaybackController(
      loadAttachment: (id) =>
          id == 'b' ? throw StateError('download failed') : Future.value(Uint8List.fromList([1])),
      engine: engine,
      nextAutoPlayVoice: (current) => current == 'a' ? _voice('b') : null,
    );

    await controller.toggle(_voice('a'));
    engine.finishNaturally();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.hasFailed('b'), isTrue, reason: '失败如实提示，可手动重试');
    expect(engine.played, hasLength(1), reason: '失败后不继续尝试更后面的语音');
    controller.dispose();
  });
}
