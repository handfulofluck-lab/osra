import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `shared_preferences` key for the parent's appearance choice. The value is
/// `system` / `light` / `dark`; an unknown or missing value means `system`.
const kThemeModeKey = 'theme_mode';

/// Persisted appearance override, matching the `ServerUrlNotifier` pattern in
/// `server_provider.dart` (same package, same async read, same silent
/// fallback when prefs are unavailable in a test).
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  final notifier = ThemeModeNotifier();
  notifier.load();
  return notifier;
});

String themeModeName(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };

ThemeMode themeModeFromName(String? name) => switch (name) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system);

  bool _disposed = false;
  bool _userChose = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Reads the persisted choice. A failure (prefs unavailable, e.g. in a unit
  /// test without the mock) leaves the system default in place. A choice the
  /// user made while the read was in flight wins over the persisted value.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = themeModeFromName(prefs.getString(kThemeModeKey));
      if (!_disposed && !_userChose) state = saved;
    } catch (_) {
      // keep ThemeMode.system
    }
  }

  /// Applies and persists [mode]. The UI updates immediately; persistence is
  /// best-effort, exactly like the server-URL override.
  Future<void> setMode(ThemeMode mode) async {
    _userChose = true;
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kThemeModeKey, themeModeName(mode));
    } catch (_) {
      // the in-memory choice still applies for this session
    }
  }
}
