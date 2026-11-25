import '../../l10n/app_localizations.dart';

/// The generated copy for the app's current locale, for the layers that have no `BuildContext` — the mutation
/// gate asks the OS for a prompt reason, and a cancelled prompt answers with a snackbar, both from inside a dio
/// interceptor.
///
/// Set from exactly one place (`FamilyShieldApp`'s `builder`), so it always matches what the screen above the
/// prompt is showing. Before the first build it is null and callers fall back to English; the OS prompt cannot
/// appear before a tap, so that window is a launch-time race we cannot reach.
class AppCopy {
  AppCopy._();

  static AppLocalizations? _current;

  static AppLocalizations? get current => _current;

  static void set(AppLocalizations value) => _current = value;
}
