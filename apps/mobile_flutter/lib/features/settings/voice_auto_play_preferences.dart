import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-40：「语音自动连播」的本地持久化。
abstract interface class VoiceAutoPlayPreferenceStore {
  Future<bool?> read();

  Future<void> write(bool value);
}

final class SharedPreferencesVoiceAutoPlayStore
    implements VoiceAutoPlayPreferenceStore {
  SharedPreferencesVoiceAutoPlayStore(this._preferences);

  static const key = 'changliao.voice.auto_play_next';

  final SharedPreferences _preferences;

  @override
  Future<bool?> read() async => _preferences.getBool(key);

  @override
  Future<void> write(bool value) async {
    final saved = await _preferences.setBool(key, value);
    if (!saved) {
      throw StateError('Voice auto-play preference was not persisted.');
    }
  }
}

/// 应用级「语音自动连播」设置（BUG-40；决策点 D7 已拍板：默认开启）。
///
/// 同会话内连续未读语音，上一条自然播完后自动播放下一条；开关关闭时
/// 行为与旧版一致（播完即停）。保存失败回滚内存值，避免"看起来关了
/// 其实没存"。
final class VoiceAutoPlayPreferences extends ChangeNotifier {
  VoiceAutoPlayPreferences({VoiceAutoPlayPreferenceStore? store})
      : _store = store;

  VoiceAutoPlayPreferenceStore? _store;
  bool _autoPlayNext = true;
  String? _errorMessage;

  bool get autoPlayNext => _autoPlayNext;
  String? get errorMessage => _errorMessage;

  void attachStore(VoiceAutoPlayPreferenceStore store) => _store = store;

  Future<void> load() async {
    try {
      final stored = await _store?.read();
      _autoPlayNext = stored ?? true;
    } catch (_) {
      _autoPlayNext = true;
    }
  }

  Future<void> setAutoPlayNext(bool value) async {
    if (_autoPlayNext == value) return;
    final previous = _autoPlayNext;
    _autoPlayNext = value;
    _errorMessage = null;
    notifyListeners();
    try {
      await _store?.write(value);
    } catch (_) {
      _autoPlayNext = previous;
      _errorMessage = '设置保存失败，请重试';
      notifyListeners();
    }
  }
}

/// 进程级单例：设置页写入、会话页读取同一份状态。
final voiceAutoPlayPreferences = VoiceAutoPlayPreferences();
