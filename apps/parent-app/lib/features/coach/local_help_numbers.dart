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
/// U+2066 (LRI) … U+2069 (PDI): a number inside a right-to-left sentence, kept in reading order.
const String LRI = '\u2066';
const String PDI = '\u2069';

class LocalHelpNumbers {
  /// The number to call for immediate danger, e.g. `999`.
  final String? emergency;

  /// The child-protection or social-service line, which differs by country.
  final String? childProtection;

  /// The crisis or suicide-prevention line, which differs by country.
  final String? crisis;

  /// How to reach the line before dialling the whole number: Qatar's `16000 (then option 4)` needs
  /// "and choose option 4" **before** the hours, so it is a step and not part of the number (#727 UI/UX).
  final String? stepEn;
  final String? stepAr;

  /// The opening hours, as the whole bracket including its parentheses, in each language. The card never
  /// works out whether a line is open (#727 UI/UX): a wrong "closed" stops a parent calling a line that
  /// would have answered, and a wrong "open" is the 2 a.m. case. The parent reads the hours and decides;
  /// what makes that safe is that the emergency number is always on the same card.
  ///
  /// `null` means the source does not state hours, and then **no bracket is shown at all**. A line open
  /// around the clock carries the Bureaus' 24-hour bracket.
  final String? hoursEn;
  final String? hoursAr;

  const LocalHelpNumbers({
    this.emergency,
    this.childProtection,
    this.crisis,
    this.stepEn,
    this.stepAr,
    this.hoursEn,
    this.hoursAr,
  });

  static const LocalHelpNumbers none = LocalHelpNumbers();

  bool get isEmpty =>
      emergency == null && childProtection == null && crisis == null;

  /// The number with direction isolates around it, in **every** language.
  ///
  /// Arabic Bureau, #727 review: in a right-to-left line the phone lays out the groups of `800 46342`
  /// from the right, so a card in Arabic shows **46342 800** — and a parent in a crisis dials what the card
  /// shows. A number with a space or a leading `+` is the case that breaks; the tests use both.
  static String isolatedNumber(String number) => '$LRI$number$PDI';

  /// The number as a sentence reads it: the dialled number, then the step, then the hours bracket —
  /// `16000 and choose option 4 (open Saturday to Thursday 08:00–18:00)`.
  ///
  /// The order is the UI/UX Bureau's: the step explains how to reach the line, so it cannot come after
  /// the hours, and both stay in the same sentence so the hours cannot drift away from the number.
  String _dial(String number, {String? step, String? hours}) {
    // The step and the bracket arrive already written in the language being rendered, so there is no
    // per-language branch here on purpose: the wording is the Bureaus', the order is this method's.
    final buffer = StringBuffer(isolatedNumber(number));
    if (step != null) buffer.write(' $step');
    if (hours != null) buffer.write(' $hours');
    return buffer.toString();
  }

  /// "call emergency services on 999", or "call your country's emergency number" when nothing is known.
  String emergencyClause({required bool arabic}) => emergency == null
      ? (arabic
          ? 'اتصل برقم الطوارئ في بلدك'
          : "call your country's emergency number")
      : (arabic
          ? 'اتصل بالطوارئ على الرقم ${_dial(emergency!, hours: hoursAr)}'
          : 'call emergency services on ${_dial(emergency!, hours: hoursEn)}');

  /// "call the crisis line on 80046342", or "call the crisis line in your country".
  String crisisClause({required bool arabic}) => crisis == null
      ? (arabic
          ? 'اتصل بخط الدعم النفسي في بلدك'
          : 'call the crisis line in your country')
      : (arabic
          ? 'اتصل بخط الدعم النفسي على الرقم '
              '${_dial(crisis!, step: stepAr, hours: hoursAr)}'
          : 'call the crisis line on '
              '${_dial(crisis!, step: stepEn, hours: hoursEn)}');

  /// "call the child-protection line on 116111", or "contact your country's child-protection service".
  String childProtectionClause({required bool arabic}) =>
      childProtection == null
          ? (arabic
              ? 'أبلغ جهة حماية الطفل في بلدك'
              : "contact your country's child-protection service")
          : (arabic
              ? 'اتصل بخط حماية الطفل على الرقم '
                  '${_dial(childProtection!, step: stepAr, hours: hoursAr)}'
              : 'call the child-protection line on '
                  '${_dial(childProtection!, step: stepEn, hours: hoursEn)}');

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
