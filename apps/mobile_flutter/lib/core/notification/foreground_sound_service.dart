import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'sound_type.dart';

/// 声音引擎抽象：可注入测试。
abstract interface class SoundEngine {
  Future<void> play(String assetPath, {double volume = 1.0});
  Future<void> playLoop(String assetPath);
  Future<void> stopLoop();
  Future<void> dispose();
}

/// 生产引擎：audioplayers。
///
/// - 一次性音效使用低延迟模式播放器；
/// - 来电铃声使用独立循环播放器（ReleaseMode.loop）；
/// - 音频上下文：Android usage=notification 且不抢占音频焦点，
///   iOS ambient（尊重静音键），遵循用户系统音量（PRD §39）。
final class AudioplayersSoundEngine implements SoundEngine {
  AudioplayersSoundEngine() {
    _oneShot = AudioPlayer(playerId: 'chatflow_sfx_one_shot')
      ..setPlayerMode(PlayerMode.lowLatency);
    _loop = AudioPlayer(playerId: 'chatflow_sfx_loop')
      ..setReleaseMode(ReleaseMode.loop);
    unawaited(_applyAudioContext());
  }

  static final AudioContext _context = AudioContext(
    android: AudioContextAndroid(
      // 即时通讯消息音：notification 通道音量、不抢占音频焦点（PRD §39）。
      usageType: AndroidUsageType.notificationCommunicationInstant,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      // ambient：尊重静音键、与其他应用混音。
      category: AVAudioSessionCategory.ambient,
    ),
  );

  late final AudioPlayer _oneShot;
  late final AudioPlayer _loop;

  Future<void> _applyAudioContext() async {
    try {
      await AudioPlayer.global.setAudioContext(_context);
    } catch (_) {
      // 平台不支持时沿用引擎默认上下文。
    }
  }

  AssetSource _source(String assetPath) =>
      AssetSource(assetPath.replaceFirst('assets/', ''));

  @override
  Future<void> play(String assetPath, {double volume = 1.0}) async {
    await _oneShot.stop();
    await _oneShot.setVolume(volume);
    await _oneShot.play(_source(assetPath));
  }

  @override
  Future<void> playLoop(String assetPath) async {
    await _loop.stop();
    await _loop.play(_source(assetPath));
  }

  @override
  Future<void> stopLoop() async {
    await _loop.stop();
  }

  @override
  Future<void> dispose() async {
    await _oneShot.dispose();
    await _loop.dispose();
  }
}

/// 前台音效服务（PRD §2：业务页面禁止直接 AudioPlayer().play）。
final class ForegroundSoundService {
  ForegroundSoundService({
    SoundEngine? engine,
    bool Function()? soundEnabled,
  })  : _engine = engine ?? AudioplayersSoundEngine(),
        _soundEnabled = soundEnabled;

  final SoundEngine _engine;
  final bool Function()? _soundEnabled;

  /// 播放一次性音效。调用方需处于前台（PRD §19：后台一律交给系统通知）。
  Future<void> play(SoundType type, {double volume = 1.0}) async {
    final enabled = _soundEnabled;
    if (enabled != null && !enabled()) return;
    try {
      await _engine.play(type.assetPath, volume: volume);
    } catch (_) {
      // 音频设备异常不影响消息链路。
    }
  }

  /// 循环铃声（来电/呼叫等待），由通话状态机控制起停。
  Future<void> startLoop(SoundType type) async {
    try {
      await _engine.playLoop(type.assetPath);
    } catch (_) {}
  }

  Future<void> stopLoop() async {
    try {
      await _engine.stopLoop();
    } catch (_) {}
  }

  Future<void> dispose() => _engine.dispose();
}
