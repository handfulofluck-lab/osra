import 'package:flutter/material.dart';

/// Spacing scale for the parent app. All screen padding and gaps come from
/// here so two screens never disagree about what "a small gap" is.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii. `xs` for chart bars and other hairline shapes, `sm` for
/// inline pills, `md` for cards/dialogs and `lg` for large sheets.
abstract final class AppRadius {
  static const double xs = 2;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

/// Elevation roles. Cards sit almost flat; dialogs lift off the surface.
abstract final class AppElevation {
  static const double flat = 0;
  static const double card = 1;
  static const double dialog = 6;
}

/// The one text-style definition. [AppTheme] publishes this as
/// `ThemeData.textTheme`, so a screen uses `Theme.of(context).textTheme.*`
/// and every screen gets the same sizes, heights and weights. Styles carry no
/// colour: Material applies the light/dark `onSurface` colour.
abstract final class AppType {
  static const TextTheme textTheme = TextTheme(
    headlineMedium: TextStyle(fontSize: 28, height: 36 / 28, fontWeight: FontWeight.w400),
    titleLarge: TextStyle(fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w400),
    titleMedium: TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w500),
    titleSmall: TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500),
    bodyLarge: TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400),
    bodyMedium: TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400),
    bodySmall: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w400),
    labelLarge: TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500),
    labelMedium: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500),
    labelSmall: TextStyle(fontSize: 11, height: 16 / 11, fontWeight: FontWeight.w500),
  );

  /// Monospaced-feeling pairing code (six digits, wide tracking).
  static const TextStyle pairingCode = TextStyle(
    fontSize: 56,
    height: 1.1,
    fontWeight: FontWeight.bold,
    letterSpacing: 12,
  );

  /// Tick labels on the fl_chart bar chart: smaller than [labelSmall] because
  /// every app name on the x-axis competes for a 320 px width.
  static const TextStyle chartTick = TextStyle(fontSize: 10, height: 1.2, fontWeight: FontWeight.w400);
}

/// Semantic colour roles for one brightness. A screen asks for a role
/// (`danger`, `surfaceVariant`, …) rather than naming a Material colour.
///
/// `danger`, `warn` and `ok` are the body-text/status roles: each keeps at
/// least 4.5:1 contrast against both [surface] and [surfaceVariant] (checked
/// by `test/design_system_test.dart`). `severityCritical`, `severityWarning`
/// and `severityInfo` are the legacy alert-dot roles. Their light values are
/// the ones the existing alert widget test pins (`Colors.red`, `Colors.amber`,
/// `Colors.blue`); dark mode re-maps them to lighter variants so the dots stay
/// visible on a dark card.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  final Color surface;
  final Color surfaceVariant;
  final Color surfaceContainer;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color border;
  final Color danger;
  final Color warn;
  final Color ok;
  final Color onDanger;
  final Color severityCritical;
  final Color severityWarning;
  final Color severityInfo;

  /// Wellbeing ring thresholds (low < 50, mid < 75, high otherwise). The
  /// light values are the Material colours the existing ring test pins.
  final Color wellbeingLow;
  final Color wellbeingMid;
  final Color wellbeingHigh;
  final double elevationCard;
  final double elevationDialog;

  const AppTokens({
    required this.surface,
    required this.surfaceVariant,
    required this.surfaceContainer,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.border,
    required this.danger,
    required this.warn,
    required this.ok,
    required this.onDanger,
    required this.severityCritical,
    required this.severityWarning,
    required this.severityInfo,
    required this.wellbeingLow,
    required this.wellbeingMid,
    required this.wellbeingHigh,
    this.elevationCard = AppElevation.card,
    this.elevationDialog = AppElevation.dialog,
  });

  static const AppTokens light = AppTokens(
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFEFEDF4),
    surfaceContainer: Color(0xFFF7F5FA),
    primary: Color(0xFF3F51B5),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFDDE1FF),
    onPrimaryContainer: Color(0xFF111C6B),
    onSurface: Color(0xFF1B1B1F),
    onSurfaceVariant: Color(0xFF46464F),
    border: Color(0xFFC7C5D0),
    danger: Color(0xFFB3261E),
    warn: Color(0xFF7A5900),
    ok: Color(0xFF1B5E20),
    onDanger: Color(0xFFFFFFFF),
    severityCritical: Colors.red, // pinned by the alert test (runtime type included)
    severityWarning: Colors.amber, // pinned by the alert test
    severityInfo: Colors.blue, // pinned by the alert test
    wellbeingLow: Colors.red, // pinned by the wellbeing ring test
    wellbeingMid: Colors.amber, // pinned by the wellbeing ring test
    wellbeingHigh: Colors.green, // pinned by the wellbeing ring test
  );

  static const AppTokens dark = AppTokens(
    surface: Color(0xFF141218),
    surfaceVariant: Color(0xFF2B2930),
    surfaceContainer: Color(0xFF1D1B20),
    primary: Color(0xFFBAC3FF),
    onPrimary: Color(0xFF1B1B5E),
    primaryContainer: Color(0xFF2E3A7A),
    onPrimaryContainer: Color(0xFFDDE1FF),
    onSurface: Color(0xFFE6E1E9),
    onSurfaceVariant: Color(0xFFCAC4D0),
    border: Color(0xFF49454F),
    danger: Color(0xFFFFB4AB),
    warn: Color(0xFFFFD37A),
    ok: Color(0xFF7CDB9E),
    onDanger: Color(0xFF690005),
    severityCritical: Color(0xFFFF8A80),
    severityWarning: Color(0xFFFFD54F),
    severityInfo: Color(0xFF82B1FF),
    wellbeingLow: Color(0xFFFF8A80),
    wellbeingMid: Color(0xFFFFD54F),
    wellbeingHigh: Color(0xFF7CDB9E),
  );

  @override
  AppTokens copyWith({
    Color? surface,
    Color? surfaceVariant,
    Color? surfaceContainer,
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? onSurface,
    Color? onSurfaceVariant,
    Color? border,
    Color? danger,
    Color? warn,
    Color? ok,
    Color? onDanger,
    Color? severityCritical,
    Color? severityWarning,
    Color? severityInfo,
    Color? wellbeingLow,
    Color? wellbeingMid,
    Color? wellbeingHigh,
    double? elevationCard,
    double? elevationDialog,
  }) {
    return AppTokens(
      surface: surface ?? this.surface,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      surfaceContainer: surfaceContainer ?? this.surfaceContainer,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      onSurface: onSurface ?? this.onSurface,
      onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
      border: border ?? this.border,
      danger: danger ?? this.danger,
      warn: warn ?? this.warn,
      ok: ok ?? this.ok,
      onDanger: onDanger ?? this.onDanger,
      severityCritical: severityCritical ?? this.severityCritical,
      severityWarning: severityWarning ?? this.severityWarning,
      severityInfo: severityInfo ?? this.severityInfo,
      wellbeingLow: wellbeingLow ?? this.wellbeingLow,
      wellbeingMid: wellbeingMid ?? this.wellbeingMid,
      wellbeingHigh: wellbeingHigh ?? this.wellbeingHigh,
      elevationCard: elevationCard ?? this.elevationCard,
      elevationDialog: elevationDialog ?? this.elevationDialog,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    Color fade(Color a, Color b) => Color.lerp(a, b, t)!;
    double mix(double a, double b) => a + (b - a) * t;
    return AppTokens(
      surface: fade(surface, other.surface),
      surfaceVariant: fade(surfaceVariant, other.surfaceVariant),
      surfaceContainer: fade(surfaceContainer, other.surfaceContainer),
      primary: fade(primary, other.primary),
      onPrimary: fade(onPrimary, other.onPrimary),
      primaryContainer: fade(primaryContainer, other.primaryContainer),
      onPrimaryContainer: fade(onPrimaryContainer, other.onPrimaryContainer),
      onSurface: fade(onSurface, other.onSurface),
      onSurfaceVariant: fade(onSurfaceVariant, other.onSurfaceVariant),
      border: fade(border, other.border),
      danger: fade(danger, other.danger),
      warn: fade(warn, other.warn),
      ok: fade(ok, other.ok),
      onDanger: fade(onDanger, other.onDanger),
      severityCritical: fade(severityCritical, other.severityCritical),
      severityWarning: fade(severityWarning, other.severityWarning),
      severityInfo: fade(severityInfo, other.severityInfo),
      wellbeingLow: fade(wellbeingLow, other.wellbeingLow),
      wellbeingMid: fade(wellbeingMid, other.wellbeingMid),
      wellbeingHigh: fade(wellbeingHigh, other.wellbeingHigh),
      elevationCard: mix(elevationCard, other.elevationCard),
      elevationDialog: mix(elevationDialog, other.elevationDialog),
    );
  }
}

/// `context.tokens` is the screen-facing entry point. Falling back to
/// [AppTokens.light] keeps standalone widget tests (which pump a bare
/// `MaterialApp`) rendering the same roles without wiring the whole theme.
extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>() ?? AppTokens.light;
}
