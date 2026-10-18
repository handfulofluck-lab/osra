import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `shared_preferences` key for the parent's language choice. The value is
/// `system` / `en` / `ar`; an unknown or missing value means `system`
/// (`null` locale, so `MaterialApp` follows the device).
const kAppLocaleKey = 'app_locale';

/// Persisted locale override, matching the `ThemeModeNotifier` pattern in
/// `theme_provider.dart` (same async read, same silent fallback when prefs are
/// unavailable in a test).
final localeProvider = StateNotifierProvider<AppLocaleNotifier, Locale?>((ref) {
  final notifier = AppLocaleNotifier();
  notifier.load();
  return notifier;
});

String appLocaleName(Locale? locale) => locale?.languageCode ?? 'system';

Locale? appLocaleFromName(String? name) => switch (name) {
      'en' => const Locale('en'),
      'ar' => const Locale('ar'),
      _ => null,
    };

class AppLocaleNotifier extends StateNotifier<Locale?> {
  AppLocaleNotifier() : super(null);

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
      final saved = appLocaleFromName(prefs.getString(kAppLocaleKey));
      if (!_disposed && !_userChose) state = saved;
    } catch (_) {
      // keep following the device locale
    }
  }

  /// Applies and persists [locale]; `null` follows the device locale.
  Future<void> setLocale(Locale? locale) async {
    _userChose = true;
    state = locale;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kAppLocaleKey, appLocaleName(locale));
    } catch (_) {
      // the in-memory choice still applies for this session
    }
  }
}
