import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

abstract interface class VoiceAudioRouteEngine {
  Future<void> setEarpiece(bool value);
}

abstract interface class DisposableVoiceAudioEngine {
  Future<void> dispose();
}

final class AudioplayersVoiceEngine
    implements
        VoiceAudioEngine,
        VoiceAudioRouteEngine,
        DisposableVoiceAudioEngine {
  AudioplayersVoiceEngine({
    AudioPlayer? player,
    this.temporaryDirectory,
  }) : _player = player ?? AudioPlayer();
  final Future<Directory> Function()? temporaryDirectory;
  final AudioPlayer _player;
  File? _temporaryFile;
  Directory? _temporaryFolder;
  bool _earpiece = false;
  static const _session = MethodChannel('chatflow/voice_audio_session');
  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _checkPlaybackAllowed() async {
    if (_isIOS) await _session.invokeMethod<void>('checkPlaybackAllowed');
  }

  Future<void> _prepareContext() async {
    if (_isIOS) {
      // Native guard and session mutation are atomic on the main queue. Do not
      // set the plugin's global category before checking CallKit ownership.
      await _session
          .invokeMethod<void>('preparePlayback', {'earpiece': _earpiece});
      return;
    }
    await _player.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: !_earpiece,
        audioMode: _earpiece
            ? AndroidAudioMode.inCommunication
            : AndroidAudioMode.normal,
        contentType: AndroidContentType.speech,
        usageType: _earpiece
            ? AndroidUsageType.voiceCommunication
            : AndroidUsageType.media,
      ),
    ));
  }

  @override
  Future<void> play(Uint8List bytes, {required bool earpiece}) async {
    _earpiece = earpiece;
    await _checkPlaybackAllowed();
    await stop();
    final mime = _containerMime(bytes);
    try {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        // Avoid the plugin's extensionless 20-bit hash filenames. Each source
        // gets its own private temporary path and is removed after release.
        final base = await (temporaryDirectory ?? getTemporaryDirectory)();
        final folder = await base.createTemp('chatflow_voice_');
        _temporaryFolder = folder;
        final extension = switch (mime) {
          'audio/mp4' => 'm4a',
          'audio/wav' => 'wav',
          'audio/aac' => 'aac',
          _ => 'bin',
        };
        final file = File('${folder.path}/audio.$extension');
        _temporaryFile = file;
        await file.writeAsBytes(bytes, flush: true);
        await _prepareContext();
        await _player.play(DeviceFileSource(file.path, mimeType: mime));
      } else {
        await _prepareContext();
        await _player.play(BytesSource(bytes, mimeType: mime));
      }
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  static String? _containerMime(Uint8List bytes) {
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45) {
      return 'audio/wav';
    }
    if (bytes.length >= 12 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return 'audio/mp4';
    }
    if (bytes.length >= 7 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0) {
      return 'audio/aac';
    }
    return null;
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() async {
    await _checkPlaybackAllowed();
    await _prepareContext();
    await _player.resume();
  }

  @override
  Future<void> setEarpiece(bool value) async {
    await _checkPlaybackAllowed();
    _earpiece = value;
    await _prepareContext();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await _deleteTemporarySource();
  }

  Future<void> _deleteTemporarySource() async {
    final file = _temporaryFile;
    if (file != null && await file.exists()) await file.delete();
    _temporaryFile = null;
    final folder = _temporaryFolder;
    if (folder != null && await folder.exists()) await folder.delete();
    _temporaryFolder = null;
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
    await _deleteTemporarySource();
  }

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
    bool Function()? canPlay,
  })  : _loadAttachment = loadAttachment,
        _canPlay = canPlay ?? _alwaysAllowPlayback,
        engine = engine ?? AudioplayersVoiceEngine() {
    // 播放自然结束时复位气泡（QQ 式播放体验）。
    _completedSubscription = this
        .engine
        .completed
        .listen((_) => _handleCompleted(), onError: _handlePlaybackError);
    _positionSubscription = this
        .engine
        .position
        .listen(_handlePosition, onError: _handlePlaybackError);
  }

  StreamSubscription<void>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  final Future<Uint8List> Function(String eventId) _loadAttachment;
  final VoiceAudioEngine engine;
  final bool Function() _canPlay;
  static bool _alwaysAllowPlayback() => true;

  final Set<String> _playingIds = <String>{};
  final Set<String> _pausedIds = <String>{};
  final Set<String> _cachedIds = <String>{};
  final Map<String, Duration> _positions = <String, Duration>{};
  bool earpiece = false;
  String? _loadingId;
  String? _failedId;
  Future<void> _operations = Future<void>.value();
  bool isLoading(String eventId) => _loadingId == eventId;
  bool hasFailed(String eventId) => _failedId == eventId;

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.catchError((Object _) {});
    return next;
  }

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
    if (_disposed || _loadingId != null || _playingIds.isEmpty) return;
    for (final id in _playingIds) {
      _positions[id] = position;
    }
    notifyListeners();
  }

  void _handleCompleted() {
    if (_disposed || _loadingId != null) return;
    if (_playingIds.isEmpty && _pausedIds.isEmpty) return;
    _playingIds.clear();
    _pausedIds.clear();
    _positions.clear();
    notifyListeners();
  }

  void _handlePlaybackError(Object error, StackTrace stackTrace) {
    // Native event errors are separate from the play() Future. Consume them
    // here without logging a source that may contain decrypted audio bytes.
    if (_disposed || _loadingId != null) return;
    _failedId = _playingIds.firstOrNull ?? _pausedIds.firstOrNull;
    _handleCompleted();
  }

  Future<void> toggle(RoomMessageViewModel message) async {
    if (_disposed) return;
    if (!_canPlay()) {
      _failedId = message.id;
      await stopAll();
      return;
    }
    if (_loadingId == message.id) {
      await stopAll();
      return;
    }
    if (isPlaying(message.id)) {
      _playingIds.remove(message.id);
      _pausedIds.add(message.id);
      notifyListeners();
      await _changePlayback(message.id, engine.pause);
      return;
    }
    if (isPaused(message.id)) {
      // 暂停中点击 → 从暂停位置继续。
      _pausedIds.remove(message.id);
      _playingIds.add(message.id);
      notifyListeners();
      await _changePlayback(message.id, engine.resume);
      return;
    }
    await _start(message);
  }

  Future<void> _changePlayback(
      String id, Future<void> Function() action) async {
    final generation = _generation;
    try {
      await _serialize(() async {
        if (_disposed || generation != _generation) return;
        if (!_canPlay()) throw StateError('Voice playback unavailable');
        try {
          await action();
        } catch (_) {
          await engine.stop();
          rethrow;
        }
      });
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _failedId = id;
      _playingIds.clear();
      _pausedIds.clear();
      _positions.clear();
      notifyListeners();
    }
  }

  Future<void> setEarpiece(bool value) async {
    if (_disposed || earpiece == value) return;
    earpiece = value;
    notifyListeners();
    final id = _playingIds.firstOrNull ?? _pausedIds.firstOrNull;
    final audioEngine = engine;
    if (id != null && audioEngine is VoiceAudioRouteEngine) {
      await _changePlayback(
          id, () => (audioEngine as VoiceAudioRouteEngine).setEarpiece(value));
    }
  }

  Future<void> _start(RoomMessageViewModel message) async {
    final hadSource = _playingIds.isNotEmpty || _pausedIds.isNotEmpty;
    final generation = ++_generation;
    _loadingId = message.id;
    _failedId = null;
    _playingIds.clear();
    _pausedIds.clear();
    _positions.clear();
    notifyListeners();
    try {
      if (hadSource) {
        await _serialize(engine.stop);
        if (_disposed || generation != _generation) return;
      }
      // 首次播放下载解密并记录；再次播放直接交给引擎重播。
      final bytes = await _loadAttachment(message.id);
      if (_disposed || generation != _generation) return;
      _cachedIds.add(message.id);
      await _serialize(() async {
        if (_disposed || generation != _generation) return;
        if (!_canPlay()) throw StateError('Voice playback unavailable');
        await engine.play(bytes, earpiece: earpiece);
        if (_disposed || generation != _generation) {
          // This cleanup still owns the queue; a newer play has not started.
          await engine.stop();
          return;
        }
        _loadingId = null;
        _playingIds.add(message.id);
      });
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _playingIds.remove(message.id);
      _loadingId = null;
      _failedId = message.id;
    }
    if (!_disposed && generation == _generation) notifyListeners();
  }

  Future<void> stopAll() async {
    // 代数递增：在途下载/播放任务完成后不得触发 play 或状态更新。
    _generation++;
    _loadingId = null;
    _playingIds.clear();
    _pausedIds.clear();
    _positions.clear();
    if (!_disposed) notifyListeners();
    await _serialize(engine.stop);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_serialize(() async {
      final audioEngine = engine;
      if (audioEngine is DisposableVoiceAudioEngine) {
        await (audioEngine as DisposableVoiceAudioEngine).dispose();
      } else {
        await audioEngine.stop();
      }
    }).catchError((Object _) {}));
    unawaited(_completedSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    super.dispose();
  }
}
