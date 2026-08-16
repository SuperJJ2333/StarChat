import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemePreference { system, light, dark }

abstract interface class ThemePreferenceStore {
  Future<String?> read();

  Future<void> write(String value);
}

final class SharedPreferencesThemePreferenceStore
    implements ThemePreferenceStore {
  SharedPreferencesThemePreferenceStore(this._preferences);

  static const key = 'changliao.theme.preference';

  final SharedPreferences _preferences;

  @override
  Future<String?> read() async => _preferences.getString(key);

  @override
  Future<void> write(String value) async {
    final saved = await _preferences.setString(key, value);
    if (!saved) {
      throw StateError('Theme preference was not persisted.');
    }
  }
}

final class ThemeController extends ChangeNotifier {
  ThemeController({required ThemePreferenceStore store}) : _store = store;

  final ThemePreferenceStore _store;
  ThemePreference _preference = ThemePreference.system;
  String? _errorMessage;

  ThemePreference get preference => _preference;
  String? get errorMessage => _errorMessage;

  Future<void> load() async {
    final stored = await _store.read();
    _preference = ThemePreference.values.firstWhere(
      (value) => value.name == stored,
      orElse: () => ThemePreference.system,
    );
  }

  Brightness resolve(Brightness platformBrightness) {
    return switch (_preference) {
      ThemePreference.system => platformBrightness,
      ThemePreference.light => Brightness.light,
      ThemePreference.dark => Brightness.dark,
    };
  }

  Future<void> setPreference(ThemePreference preference) async {
    if (_preference == preference) return;
    final previous = _preference;
    _preference = preference;
    _errorMessage = null;
    notifyListeners();
    try {
      await _store.write(preference.name);
    } catch (_) {
      _preference = previous;
      _errorMessage = '主题设置保存失败，请重试';
      notifyListeners();
    }
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }
}
