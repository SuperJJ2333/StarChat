import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'room_timeline_controller.dart';

abstract interface class VoiceAudioEngine {
  Future<void> play(Uint8List bytes, {required bool earpiece});

  /// 暂停：保留播放位置（高亮定格）。
  Future<void> pause();

  /// 从暂停位置继续播放。
  Future<void> resume();

  Future<void> stop();

  /// 播放位置（实时）：驱动气泡扫过动效与真实进度展示。
  Stream<Duration> get position;

  /// 播放自然结束事件：用于把气泡复位为空闲态。
  Stream<void> get completed;
}

final class AudioplayersVoiceEngine implements VoiceAudioEngine {
  AudioplayersVoiceEngine({AudioPlayer? player})
      : _player = player ?? AudioPlayer();
  final AudioPlayer _player;

  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async {
    // 听筒模式：voiceCommunication 路由到听筒；扬声器：默认媒体路由。
    await _player.setAudioContext(AudioContextConfig(
      route: earpiece
          ? AudioContextConfigRoute.earpiece
          : AudioContextConfigRoute.system,
      respectSilence: false,
    ).build());
    await _player.stop();
    await _player.play(BytesSource(bytes));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<Duration> get position => _player.onPositionChanged;

  @override
  Stream<void> get completed => _player.onPlayerComplete;
}

enum VoicePlaybackState { idle, downloading, playing }

/// 语音消息播放控制：点击气泡 → 下载（本地缓存）→ 播放；
/// 播放中点击 → 暂停（高亮定格）；暂停中点击 → 从暂停位置继续；
/// 播放自然结束自动复位。同一时间只有一条语音处于播放/暂停态。
final class VoicePlaybackController extends ChangeNotifier {
  VoicePlaybackController({
    required Future<Uint8List> Function(String eventId) loadAttachment,
    VoiceAudioEngine? engine,
  })  : _loadAttachment = loadAttachment,
        engine = engine ?? AudioplayersVoiceEngine() {
    // 播放自然结束时复位气泡（QQ 式播放体验）。
    _completedSubscription =
        this.engine.completed.listen((_) => _handleCompleted());
    _positionSubscription = this.engine.position.listen(_handlePosition);
  }

  StreamSubscription<void>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  final Future<Uint8List> Function(String eventId) _loadAttachment;
  final VoiceAudioEngine engine;

  final Set<String> _playingIds = <String>{};
  final Set<String> _pausedIds = <String>{};
  final Set<String> _cachedIds = <String>{};
  final Map<String, Duration> _positions = <String, Duration>{};
  bool earpiece = false;

  /// M02：每次新的播放意图递增代数；下载/播放的每个 await 之后校验，
  /// stopAll/dispose/新任务使旧任务失效——B 后完成时 A 的迟到加载
  /// 不得触发 play 或 notifyListeners。
  int _generation = 0;
  bool _disposed = false;

  Set<String> get playingIds => Set.unmodifiable(_playingIds);
  bool isPlaying(String eventId) => _playingIds.contains(eventId);

  /// 暂停态：高亮定格在暂停位置，再次点击从该位置继续。
  bool isPaused(String eventId) => _pausedIds.contains(eventId);
  bool isCached(String eventId) => _cachedIds.contains(eventId);

  /// 该语音当前的播放位置（未播放/未上报时为 null）。
  Duration? positionOf(String eventId) => _positions[eventId];

  void _handlePosition(Duration position) {
    if (_playingIds.isEmpty) return;
    for (final id in _playingIds) {
      _positions[id] = position;
    }
    notifyListeners();
  }

  void _handleCompleted() {
    if (_playingIds.isEmpty && _pausedIds.isEmpty) return;
    _playingIds.clear();
    _pausedIds.clear();
    _positions.clear();
    notifyListeners();
  }

  Future<void> toggle(RoomMessageViewModel message) async {
    if (isPlaying(message.id)) {
      // 播放中点击 → 暂停：高亮定格当前位置。
      await engine.pause();
      _playingIds.remove(message.id);
      _pausedIds.add(message.id);
      notifyListeners();
      return;
    }
    if (isPaused(message.id)) {
      // 暂停中点击 → 从暂停位置继续。
      _pausedIds.remove(message.id);
      _playingIds.add(message.id);
      notifyListeners();
      await engine.resume();
      return;
    }
    await _start(message);
  }

  Future<void> _start(RoomMessageViewModel message) async {
    final generation = ++_generation;
    _playingIds
      ..clear()
      ..add(message.id);
    _pausedIds.clear();
    notifyListeners();
    try {
      // 首次播放下载解密并记录；再次播放直接交给引擎重播。
      final bytes = await _loadAttachment(message.id);
      if (_disposed || generation != _generation) return;
      _cachedIds.add(message.id);
      await engine.play(bytes, earpiece: earpiece);
      if (_disposed || generation != _generation) {
        // play 返回前播放归属已变更（新任务已接管引擎）——极小窗口的
        // 迟到播放立即停掉，不与新任务争抢引擎。
        await engine.stop();
        return;
      }
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _playingIds.remove(message.id);
    }
    if (!_disposed && generation == _generation) notifyListeners();
  }

  Future<void> stopAll() async {
    // 代数递增：在途下载/播放任务完成后不得触发 play 或状态更新。
    _generation++;
    await engine.stop();
    _playingIds.clear();
    _pausedIds.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(engine.stop());
    unawaited(_completedSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    super.dispose();
  }
}
