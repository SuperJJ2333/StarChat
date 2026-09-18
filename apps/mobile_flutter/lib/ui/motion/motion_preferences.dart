import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「减少动态效果」的本地持久化。
abstract interface class MotionPreferenceStore {
  Future<bool?> read();

  Future<void> write(bool value);
}

final class SharedPreferencesMotionPreferenceStore
    implements MotionPreferenceStore {
  SharedPreferencesMotionPreferenceStore(this._preferences);

  static const key = 'changliao.motion.reduce_effects';

  final SharedPreferences _preferences;

  @override
  Future<bool?> read() async => _preferences.getBool(key);

  @override
  Future<void> write(bool value) async {
    final saved = await _preferences.setBool(key, value);
    if (!saved) {
      throw StateError('Motion preference was not persisted.');
    }
  }
}

/// 应用级「减少动态效果」设置（BUG-08）。
///
/// 保存失败时回滚内存值并给出错误文案，避免"看起来开了其实没存"。
final class MotionPreferences extends ChangeNotifier {
  MotionPreferences({MotionPreferenceStore? store}) : _store = store;

  MotionPreferenceStore? _store;
  bool _reduceMotion = false;
  String? _errorMessage;

  bool get reduceMotion => _reduceMotion;
  String? get errorMessage => _errorMessage;

  void attachStore(MotionPreferenceStore store) => _store = store;

  Future<void> load() async {
    try {
      final stored = await _store?.read();
      _reduceMotion = stored ?? false;
    } catch (_) {
      _reduceMotion = false;
    }
  }

  Future<void> setReduceMotion(bool value) async {
    if (_reduceMotion == value) return;
    final previous = _reduceMotion;
    _reduceMotion = value;
    _errorMessage = null;
    notifyListeners();
    try {
      await _store?.write(value);
    } catch (_) {
      _reduceMotion = previous;
      _errorMessage = '设置保存失败，请重试';
      notifyListeners();
    }
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }
}

/// 进程级单例：设置页写入、应用根与路由读取同一份状态。
final motionPreferences = MotionPreferences();

/// 路由在拿不到 [MediaQuery] 时的兜底读取口（测试可覆盖）。
bool Function() motionReduceMotionResolver = () => motionPreferences.reduceMotion;
