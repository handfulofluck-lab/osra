import 'package:flutter/widgets.dart';

/// Issue #723: the numbers a coaching card tells a parent to call.
///
/// A card never prints a placeholder. Three fields may each be absent, and a
/// missing field becomes a sentence with no number in it — "call your local
/// emergency number" — because a wrong number in a self-harm or grooming card
/// is worse than no number at all.
///
/// The table is keyed by ISO 3166-1 alpha-2 country code. The country comes
/// from the parent's device region (`PlatformDispatcher.locale.countryCode`),
/// because no country is stored on the family yet; a family country is a
/// schema and UI change of its own (#723, Claude's decision of 13 Nov).
///
/// **The numbers are not ours to guess.** Rows arrive from Claude (architecture
/// + testing), one official source URL per number, recorded beside the row.
/// Until a country is in the table it resolves through the region fallback
/// below, which Claude authorised for the emergency number only.
class LocalHelpNumbers {
  /// The number to call for immediate danger, e.g. `999`.
  final String? emergency;

  /// The child-protection or social-service line, which differs by country.
  final String? childProtection;

  /// The crisis or suicide-prevention line, which differs by country.
  final String? crisis;

  const LocalHelpNumbers({this.emergency, this.childProtection, this.crisis});

  static const LocalHelpNumbers none = LocalHelpNumbers();

  bool get isEmpty =>
      emergency == null && childProtection == null && crisis == null;

  /// "call 999", or "call your local emergency number" when nothing is known.
  String emergencyClause({required bool arabic}) => emergency == null
      ? (arabic
          ? 'اتصل برقم الطوارئ المحلي'
          : 'call your local emergency number')
      : (arabic ? 'اتصل بـ $emergency' : 'call $emergency');

  /// "call 800 46342", or "call your local crisis line" when nothing is known.
  String crisisClause({required bool arabic}) => crisis == null
      ? (arabic ? 'اتصل بخط الأزمات المحلي' : 'call your local crisis line')
      : (arabic ? 'اتصل بـ $crisis' : 'call $crisis');

  /// "contact 116 111", or "contact your local child-protection service".
  String childProtectionClause({required bool arabic}) =>
      childProtection == null
          ? (arabic
              ? 'تواصل مع جهة حماية الطفل المحلية'
              : 'contact your local child-protection service')
          : (arabic ? 'تواصل مع $childProtection' : 'contact $childProtection');

  @override
  bool operator ==(Object other) =>
      other is LocalHelpNumbers &&
      other.emergency == emergency &&
      other.childProtection == childProtection &&
      other.crisis == crisis;

  @override
  int get hashCode => Object.hash(emergency, childProtection, crisis);

  @override
  String toString() =>
      'LocalHelpNumbers(emergency: $emergency, childProtection: $childProtection, crisis: $crisis)';
}

/// Country rows. Each row carries the source URL for each number in the comment
/// above it. Empty on purpose until those sources arrive: a guessed number is
/// not a number this app may print.
const Map<String, LocalHelpNumbers> helpNumbersByCountry =
    <String, LocalHelpNumbers>{
  // Rows land here from Claude (#723). Nothing is inferred from a country's
  // neighbours or from its region — only the emergency number has a region
  // fallback, and only for the three regions the family model carries.
};

/// Region to emergency number, the only field a region may fill. A region never
/// fills the child-protection or crisis field: those differ inside a region.
const Map<String, String> _emergencyByRegion = <String, String>{
  'US': '911',
  'EU': '112',
  'UK': '999',
};

/// Resolves the numbers for [countryCode] (ISO 3166-1 alpha-2, e.g. `AE`), with
/// [region] (`US`, `EU`, `UK`, `OTHER`) as the fallback for the emergency
/// number only.
///
/// A country row wins outright; a region fills the emergency number when the
/// country has no row, or has a row that leaves it empty.
LocalHelpNumbers resolveHelpNumbers({
  String? countryCode,
  String? region,
  Map<String, LocalHelpNumbers> table = helpNumbersByCountry,
}) {
  final country = countryCode?.trim().toUpperCase();
  final row = country == null || country.isEmpty
      ? LocalHelpNumbers.none
      : table[country];
  final base = row ?? LocalHelpNumbers.none;
  final emergency =
      base.emergency ?? _emergencyByRegion[region?.trim().toUpperCase()];
  if (emergency == base.emergency) return base;
  return LocalHelpNumbers(
    emergency: emergency,
    childProtection: base.childProtection,
    crisis: base.crisis,
  );
}

/// The region the app can see without asking the server: the parent's device
/// locale, whose country part is empty on a language-only locale (`ar`, `en`).
String? deviceCountryCode() {
  final code = WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  return code == null || code.isEmpty ? null : code.toUpperCase();
}

/// Substitutes the three tokens a coaching card may carry. A card that carries
/// no token is returned unchanged.
String fillHelpNumbers(String text, LocalHelpNumbers numbers,
        {required bool arabic}) =>
    text
        .replaceAll('{emergency}', numbers.emergencyClause(arabic: arabic))
        .replaceAll('{crisis}', numbers.crisisClause(arabic: arabic))
        .replaceAll(
            '{childProtection}', numbers.childProtectionClause(arabic: arabic));
