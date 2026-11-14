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

/// The 24-hour bracket, worded once by the Bureaus: `(open 24 hours)` is the UI/UX Bureau's
/// (#727 6869971353), `(يعمل على مدار الساعة)` the Arabic Language Bureau's (6869947527).
///
/// A row carries it only where that line's source says it runs around the clock. A `null` hours
/// field never turns into this string: "not stated" means unknown, never 24 hours (Claude, 6869832567).
const String open24hEn = '(open 24 hours)';
const String open24hAr = '(يعمل على مدار الساعة)';

class LocalHelpNumbers {
  /// The number to call for immediate danger, e.g. `999`.
  final String? emergency;

  /// The child-protection or social-service line, which differs by country.
  final String? childProtection;

  /// The crisis or suicide-prevention line, which differs by country.
  final String? crisis;

  /// How to reach the line before dialling the whole number: Qatar's `16000 (then option 4)` needs
  /// "and choose option 4" **before** the hours, so it is a step and not part of the number (#727 UI/UX).
  /// It belongs to the crisis line; no row carries a step on its child-protection line.
  final String? stepEn;
  final String? stepAr;

  /// The opening hours, as the whole bracket including its parentheses, **per line**, in each
  /// language. The card never works out whether a line is open (#727 UI/UX): a wrong "closed" stops a
  /// parent calling a line that would have answered, and a wrong "open" is the 2 a.m. case. The parent
  /// reads the hours and decides; what makes that safe is that the emergency number is always on the
  /// same card.
  ///
  /// They are per line and not per row because a country's child-protection line and its crisis line
  /// close at different times — Saudi Arabia's child line runs 07:00–23:00 and its crisis line
  /// 08:00–20:00, plus Saturdays (#727 Arabic Bureau) — and a bracket printed after the wrong line is
  /// exactly the 2 a.m. call this change exists to prevent.
  ///
  /// `null` means the source does not state hours for that line, and then **no bracket is shown at
  /// all**. A line open around the clock carries [open24hEn] / [open24hAr] in the table.
  final String? emergencyHoursEn;
  final String? emergencyHoursAr;
  final String? childProtectionHoursEn;
  final String? childProtectionHoursAr;
  final String? crisisHoursEn;
  final String? crisisHoursAr;

  const LocalHelpNumbers({
    this.emergency,
    this.childProtection,
    this.crisis,
    this.stepEn,
    this.stepAr,
    this.emergencyHoursEn,
    this.emergencyHoursAr,
    this.childProtectionHoursEn,
    this.childProtectionHoursAr,
    this.crisisHoursEn,
    this.crisisHoursAr,
  });

  static const LocalHelpNumbers none = LocalHelpNumbers();

  bool get isEmpty =>
      emergency == null && childProtection == null && crisis == null;

  /// The number as the card shows it: direction isolates around it in **every** language, and
  /// non-breaking spaces (U+00A0) where the number has ordinary ones.
  ///
  /// Arabic Bureau, #727 review: in a right-to-left line the phone lays out the groups of `800 46342`
  /// from the right, so a card in Arabic shows **46342 800** — and a parent in a crisis dials what the card
  /// shows. A number with a space or a leading `+` is the case that breaks; the tests use both.
  ///
  /// UI/UX Bureau, #727 6869971353: a space inside a number is also where a narrow card breaks it,
  /// `0808 800` on one line and `5000` on the next. U+00A0 keeps it on one line. This is the **shown**
  /// form only: the field itself keeps ordinary digits and ordinary spaces, because that is what is
  /// dialled or copied.
  static String isolatedNumber(String number) =>
      '$LRI${number.replaceAll(' ', '\u00A0')}$PDI';

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
          ? 'اتصل بالطوارئ على الرقم ${_dial(emergency!, hours: emergencyHoursAr)}'
          : 'call emergency services on ${_dial(emergency!, hours: emergencyHoursEn)}');

  /// "call the crisis line on 80046342", or "call the crisis line in your country".
  String crisisClause({required bool arabic}) => crisis == null
      ? (arabic
          ? 'اتصل بخط الدعم النفسي في بلدك'
          : 'call the crisis line in your country')
      : (arabic
          ? 'اتصل بخط الدعم النفسي على الرقم '
              '${_dial(crisis!, step: stepAr, hours: crisisHoursAr)}'
          : 'call the crisis line on '
              '${_dial(crisis!, step: stepEn, hours: crisisHoursEn)}');

  /// "call the child-protection line on 116111", or "contact your country's child-protection service".
  String childProtectionClause({required bool arabic}) =>
      childProtection == null
          ? (arabic
              ? 'أبلغ جهة حماية الطفل في بلدك'
              : "contact your country's child-protection service")
          : (arabic
              ? 'اتصل بخط حماية الطفل على الرقم '
                  '${_dial(childProtection!, hours: childProtectionHoursAr)}'
              : 'call the child-protection line on '
                  '${_dial(childProtection!, hours: childProtectionHoursEn)}');

  @override
  bool operator ==(Object other) =>
      other is LocalHelpNumbers &&
      other.emergency == emergency &&
      other.childProtection == childProtection &&
      other.crisis == crisis &&
      other.stepEn == stepEn &&
      other.stepAr == stepAr &&
      other.emergencyHoursEn == emergencyHoursEn &&
      other.emergencyHoursAr == emergencyHoursAr &&
      other.childProtectionHoursEn == childProtectionHoursEn &&
      other.childProtectionHoursAr == childProtectionHoursAr &&
      other.crisisHoursEn == crisisHoursEn &&
      other.crisisHoursAr == crisisHoursAr;

  @override
  int get hashCode => Object.hash(
        emergency,
        childProtection,
        crisis,
        stepEn,
        stepAr,
        emergencyHoursEn,
        emergencyHoursAr,
        childProtectionHoursEn,
        childProtectionHoursAr,
        crisisHoursEn,
        crisisHoursAr,
      );

  @override
  String toString() =>
      'LocalHelpNumbers(emergency: $emergency, childProtection: $childProtection, crisis: $crisis)';
}

/// Country rows, ISO 3166-1 alpha-2. Each row carries the source URL for each number in the comment
/// above it, and the hours only where that number's own source states them.
///
/// Only the cells #723 marks *ship* are here; an *empty* or *hold* cell is `null`, which renders the
/// sentence instead of a number. Hours are `null` unless the source states them: "not stated" means
/// unknown, never 24 hours (Claude, #727 6869832567).
const Map<String, LocalHelpNumbers> helpNumbersByCountry =
    <String, LocalHelpNumbers>{
  // United Arab Emirates.
  //   999      https://u.ae/en/information-and-services/justice-safety-and-the-law/handling-emergencies
  //   116111   https://u.ae/en/information-and-services/justice-safety-and-the-law/children-safety/report-child-abuse
  //            (the source states no hours, so the card shows none)
  //   800 4673 https://hope.hw.gov.ae, the National Program for Happiness and Wellbeing mental
  //            support line: daily 08:00-20:00, Ramadan 12:00-24:00 (#727 6869947527)
  'AE': LocalHelpNumbers(
    emergency: '999',
    childProtection: '116111',
    crisis: '800 4673',
    crisisHoursEn: '(open daily 08:00–20:00; in Ramadan noon to midnight)',
    crisisHoursAr:
        '(يعمل يوميًا من 08:00 إلى 20:00، وفي رمضان من 12:00 إلى منتصف الليل)',
  ),

  // Saudi Arabia.
  //   999      https://www.cst.gov.sa/en/about/Numbering (police; 997 is the ambulance). 911 works
  //            in Riyadh, Makkah, Madinah and the Eastern Province only (spa.gov.sa/en/N2525906),
  //            so 999 is the one number the field can carry for the whole Kingdom.
  //   116111   https://childhelplineinternational.org/saudi-arabia-saudi-child-helpline-116111/
  //            (Monday through Sunday, 07:00-23:00)
  //   920033360 https://www.moh.gov.sa/en/ministry/information-and-services/pages/psychiatry.aspx
  //            (08:00-20:00, and Saturdays 13:00-20:00; architect's ruling #727 6869989999)
  'SA': LocalHelpNumbers(
    emergency: '999',
    childProtection: '116111',
    crisis: '920033360',
    childProtectionHoursEn: '(open daily 07:00–23:00)',
    childProtectionHoursAr: '(يعمل يوميًا من 07:00 إلى 23:00)',
    crisisHoursEn: '(open 08:00–20:00; Saturdays 13:00–20:00)',
    crisisHoursAr: '(يعمل من 08:00 إلى 20:00، ويوم السبت من 13:00 إلى 20:00)',
  ),

  // Qatar.
  //   999   Ministry of Interior, quoted at https://www.gulf-times.com/article/732466
  //   919   https://childhelplineinternational.org/qatar-hotline-919/
  //   16000 https://www.hamad.qa, the National Mental Health Helpline, then option 4
  //         (Saturday to Thursday 08:00-18:00)
  'QA': LocalHelpNumbers(
    emergency: '999',
    childProtection: '919',
    crisis: '16000',
    stepEn: 'and choose option 4',
    stepAr: 'ثم اختر الرقم 4',
    crisisHoursEn: '(open Saturday to Thursday 08:00–18:00)',
    crisisHoursAr: '(يعمل من السبت إلى الخميس من 08:00 إلى 18:00)',
  ),

  // Kuwait.
  //   112 https://www.e.gov.kw (Essential Services: Emergencies)
  //   147 https://childhelplineinternational.org/kuwait-help-hotline-147/
  //   crisis: held on #723 — 151 is the Ministry's general advice line, and only newspapers say it
  //   offers psychological support.
  'KW': LocalHelpNumbers(emergency: '112', childProtection: '147'),

  // Bahrain.
  //   999 https://www.bahrain.bh (Emergency Call Centre)
  //   998 https://www.bahrain.bh (Child Protection Centre), answered around the clock (#723)
  'BH': LocalHelpNumbers(
    emergency: '999',
    childProtection: '998',
    childProtectionHoursEn: open24hEn,
    childProtectionHoursAr: open24hAr,
  ),

  // Oman.
  //   9999 https://www.omanobserver.om/article/75915 (Royal Oman Police) and the gov.uk Oman guidance
  //   1100 https://www.unicef.org/oman/protection-children-violence (24 hours)
  'OM': LocalHelpNumbers(
    emergency: '9999',
    childProtection: '1100',
    childProtectionHoursEn: open24hEn,
    childProtectionHoursAr: open24hAr,
  ),

  // Jordan.
  //   911 https://form.jordan.gov.jo (Important Numbers)
  //   110 https://childhelplineinternational.org/jordan-jrf-110-helpline/
  //       (Sunday to Thursday 08:00-20:00, Friday and Saturday 09:00-17:00)
  'JO': LocalHelpNumbers(
    emergency: '911',
    childProtection: '110',
    childProtectionHoursEn:
        '(open Sunday to Thursday 08:00–20:00, Friday and Saturday 09:00–17:00)',
    childProtectionHoursAr:
        '(يعمل من الأحد إلى الخميس من 08:00 إلى 20:00، ويومي الجمعة والسبت من 09:00 إلى 17:00)',
  ),

  // Egypt.
  //   122   https://www.gov.uk/foreign-travel-advice/egypt/getting-help
  //   16000 https://childhelplineinternational.org/egypt-child-helpline-egypt/ (24 hours)
  //   crisis: 16328 held on #723 — the Ministry of Health page refuses automated reading.
  'EG': LocalHelpNumbers(
    emergency: '122',
    childProtection: '16000',
    childProtectionHoursEn: open24hEn,
    childProtectionHoursAr: open24hAr,
  ),

  // Turkey.
  //   112 Interior Ministry, Oct 2021 (https://www.milliyet.com.tr)
  //   183 https://www.aile.gov.tr (ALO 183), 24 hours
  //   crisis: Turkey has no state suicide line (#723).
  'TR': LocalHelpNumbers(
    emergency: '112',
    childProtection: '183',
    childProtectionHoursEn: open24hEn,
    childProtectionHoursAr: open24hAr,
  ),

  // United States.
  //   911            https://www.childwelfare.gov/topics/responding/reporting/
  //   1-800-422-4453 https://www.childwelfare.gov/topics/responding/reporting/ (Childhelp, 24 hours)
  //   988            https://www.samhsa.gov/find-support/in-crisis (24 hours)
  'US': LocalHelpNumbers(
    emergency: '911',
    childProtection: '1-800-422-4453',
    crisis: '988',
    childProtectionHoursEn: open24hEn,
    childProtectionHoursAr: open24hAr,
    crisisHoursEn: open24hEn,
    crisisHoursAr: open24hAr,
  ),

  // United Kingdom.
  //   999            https://www.gov.uk/reportchildabuse
  //   0808 800 5000  https://learning.nspcc.org.uk/services/nspcc-helpline
  //                  NSPCC helpline, Monday to Friday 10:00-16:00 — the architect's ruling
  //                  (#727 6869989999). The 08:00-22:00 hours with weekends in #723 are older and
  //                  could not be confirmed on the day of the ruling.
  //   116 123        https://www.nhs.uk (help for suicidal thoughts); the source states no hours
  'GB': LocalHelpNumbers(
    emergency: '999',
    childProtection: '0808 800 5000',
    crisis: '116 123',
    childProtectionHoursEn: '(open Monday to Friday 10:00–16:00)',
    childProtectionHoursAr: '(يعمل من الاثنين إلى الجمعة من 10:00 إلى 16:00)',
  ),
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
    stepEn: base.stepEn,
    stepAr: base.stepAr,
    emergencyHoursEn: base.emergencyHoursEn,
    emergencyHoursAr: base.emergencyHoursAr,
    childProtectionHoursEn: base.childProtectionHoursEn,
    childProtectionHoursAr: base.childProtectionHoursAr,
    crisisHoursEn: base.crisisHoursEn,
    crisisHoursAr: base.crisisHoursAr,
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
