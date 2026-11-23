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

  /// One one-time recovery code (`XXXX-XXXX-XXXX-XXXX`). A fixed-width face
  /// keeps the hyphen groups aligned when the parent reads them back.
  static const TextStyle recoveryCode = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w500,
    fontFamily: 'monospace',
    letterSpacing: 0.4,
  );
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
/// visible on a dark card. Those dot roles are graphics, not text: `amber` on
/// white is 1.63:1 by design (the pin), so severity *labels* use the separate
/// `severityCriticalText` / `severityWarningText` / `severityInfoText` roles,
/// which are ≥ 4.5:1 on both surfaces and on their own 15% tint.
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
  final Color inputBorder;
  final Color danger;
  final Color warn;
  final Color ok;
  final Color onDanger;
  final Color onOk;
  final Color severityCritical;
  final Color severityWarning;
  final Color severityInfo;

  /// Text-safe severity foregrounds for labels and chips. The dot roles above
  /// stay pinned to the Material values; these are the accessible pair.
  final Color severityCriticalText;
  final Color severityWarningText;
  final Color severityInfoText;

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
    required this.inputBorder,
    required this.danger,
    required this.warn,
    required this.ok,
    required this.onDanger,
    required this.onOk,
    required this.severityCritical,
    required this.severityWarning,
    required this.severityInfo,
    required this.severityCriticalText,
    required this.severityWarningText,
    required this.severityInfoText,
    required this.wellbeingLow,
    required this.wellbeingMid,
    required this.wellbeingHigh,
    this.elevationCard = AppElevation.card,
    this.elevationDialog = AppElevation.dialog,
  });

  /// Calm light palette from `docs/design/tokens.json` (ADR-0038, #650 U20).
  static const AppTokens light = AppTokens(
    surface: Color(0xFFF1F5F4), // color.page.light
    surfaceVariant: Color(0xFFFFFFFF), // color.card.light
    surfaceContainer: Color(0xFFFFFFFF), // color.raised.light
    primary: Color(0xFF0B5D57), // color.primary.light
    onPrimary: Color(0xFFFFFFFF), // color.onPrimary.light
    primaryContainer: Color(0xFFEAF2F0), // color.tint.light
    onPrimaryContainer: Color(0xFF12211F), // color.ink.light
    onSurface: Color(0xFF12211F), // color.ink.light
    onSurfaceVariant: Color(0xFF4D5E5A), // color.muted.light
    border: Color(0xFFC9D6D3), // color.border.light
    inputBorder: Color(0xFF6E7E7B), // color.inputBorder.light
    danger: Color(0xFFA3242B), // color.danger.light
    warn: Color(0xFF8A4B00), // color.warn.light
    ok: Color(0xFF0B5D57), // color.ok.light
    onDanger: Color(0xFFFFFFFF), // color.onDanger.light
    onOk: Color(0xFFFFFFFF), // color.onPrimary.light
    severityCritical: Colors.red, // pinned by the alert test (runtime type included)
    severityWarning: Colors.amber, // pinned by the alert test
    severityInfo: Colors.blue, // pinned by the alert test
    severityCriticalText: Color(0xFFA3242B), // color.danger.light
    severityWarningText: Color(0xFF8A4B00), // color.warn.light
    severityInfoText: Color(0xFF1F4E9A), // usageCategory.learning.light
    wellbeingLow: Colors.red, // pinned by the wellbeing ring test
    wellbeingMid: Colors.amber, // pinned by the wellbeing ring test
    wellbeingHigh: Colors.green, // pinned by the wellbeing ring test
  );

  /// Control room dark palette from `docs/design/tokens.json` (ADR-0038, #650 U20).
  static const AppTokens dark = AppTokens(
    surface: Color(0xFF0E1417), // color.page.dark
    surfaceVariant: Color(0xFF172026), // color.card.dark
    surfaceContainer: Color(0xFF1E2A31), // color.raised.dark
    primary: Color(0xFF7DB4FF), // color.primary.dark
    onPrimary: Color(0xFF0E1417), // color.onPrimary.dark
    primaryContainer: Color(0xFF1E2A31), // color.tint.dark
    onPrimaryContainer: Color(0xFFE9EFF1), // color.ink.dark
    onSurface: Color(0xFFE9EFF1), // color.ink.dark
    onSurfaceVariant: Color(0xFFA7B6BD), // color.muted.dark
    border: Color(0xFF3A4A53), // color.border.dark
    inputBorder: Color(0xFF6A7C86), // color.inputBorder.dark
    danger: Color(0xFFFF9A8C), // color.danger.dark
    warn: Color(0xFFFFB454), // color.warn.dark
    ok: Color(0xFF86D4BE), // color.ok.dark
    onDanger: Color(0xFF0E1417), // color.onDanger.dark
    onOk: Color(0xFF0E1417), // color.onPrimary.dark
    severityCritical: Color(0xFFFF9A8C), // color.danger.dark
    severityWarning: Color(0xFFFFB454), // color.warn.dark
    severityInfo: Color(0xFF7DB4FF), // color.primary.dark
    severityCriticalText: Color(0xFFFF9A8C), // color.danger.dark
    severityWarningText: Color(0xFFFFB454), // color.warn.dark
    severityInfoText: Color(0xFF7DB4FF), // color.primary.dark
    wellbeingLow: Color(0xFFFF9A8C), // color.danger.dark
    wellbeingMid: Color(0xFFFFB454), // color.warn.dark
    wellbeingHigh: Color(0xFF86D4BE), // color.ok.dark
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
    Color? inputBorder,
    Color? danger,
    Color? warn,
    Color? ok,
    Color? onDanger,
    Color? onOk,
    Color? severityCritical,
    Color? severityWarning,
    Color? severityInfo,
    Color? severityCriticalText,
    Color? severityWarningText,
    Color? severityInfoText,
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
      inputBorder: inputBorder ?? this.inputBorder,
      danger: danger ?? this.danger,
      warn: warn ?? this.warn,
      ok: ok ?? this.ok,
      onDanger: onDanger ?? this.onDanger,
      onOk: onOk ?? this.onOk,
      severityCritical: severityCritical ?? this.severityCritical,
      severityWarning: severityWarning ?? this.severityWarning,
      severityInfo: severityInfo ?? this.severityInfo,
      severityCriticalText: severityCriticalText ?? this.severityCriticalText,
      severityWarningText: severityWarningText ?? this.severityWarningText,
      severityInfoText: severityInfoText ?? this.severityInfoText,
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
      inputBorder: fade(inputBorder, other.inputBorder),
      danger: fade(danger, other.danger),
      warn: fade(warn, other.warn),
      ok: fade(ok, other.ok),
      onDanger: fade(onDanger, other.onDanger),
      onOk: fade(onOk, other.onOk),
      severityCritical: fade(severityCritical, other.severityCritical),
      severityWarning: fade(severityWarning, other.severityWarning),
      severityInfo: fade(severityInfo, other.severityInfo),
      severityCriticalText: fade(severityCriticalText, other.severityCriticalText),
      severityWarningText: fade(severityWarningText, other.severityWarningText),
      severityInfoText: fade(severityInfoText, other.severityInfoText),
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

/// One lookup for the severity rule shared by the alerts feed, the concerns
/// vault, the search-safety list and the decryption modal. [severityDot] is
/// the icon/dot palette that the alert test pins; [severityText] is its
/// readable pair for labels.
extension AppSeverityTokens on AppTokens {
  Color severityDot(String severity) => switch (severity.toLowerCase()) {
        'critical' => severityCritical,
        'warning' => severityWarning,
        _ => severityInfo,
      };

  Color severityText(String severity) => switch (severity.toLowerCase()) {
        'critical' => severityCriticalText,
        'warning' => severityWarningText,
        _ => severityInfoText,
      };
}
