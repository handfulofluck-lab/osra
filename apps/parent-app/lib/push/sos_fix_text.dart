import '../api/models.dart';
import '../l10n/l10n.dart';

/// Issue #672: one place that turns an SOS alert's [AlertFix] into the words a parent reads, so the
/// notification, the alert's detail and the map pin cannot disagree about how old the fix is.
///
/// The two Bureaus pulled this in opposite directions and both are right:
/// - **UI/UX:** the lock screen says only that a location exists and how old it is; the numbers live in
///   the alert's detail, where a parent can read them to someone on the phone.
/// - **Arabic:** a sentence with a number in it is one whole line per plural case, never pieces joined in
///   code, and a coordinate pair inside a right-to-left line must be isolated or it draws longitude first.
///
/// So the age is computed once here, and the lines that carry numbers are the l10n ones:
/// [notificationBody] (no coordinates), [locationLine] (the Arabic Bureau's own sentence, coordinates
/// wrapped in LRI/PDI), [accuracyClause] and [pinCaption].
///
/// Rounding is always **up**: a parent must never be told a fix is fresher than it is. 119 minutes is
/// "about 2 hours", not "1 h ago" (Arabic Language Bureau, #672 review).
class SosFixText {
  /// Whole minutes, floored, never below 1.
  final int ageMinutes;

  /// Whole hours, rounded DOWN, and the line says "more than", never below 1.
  final int ageHours;

  final bool underAnHour;

  const SosFixText._({required this.ageMinutes, required this.ageHours, required this.underAnHour});

  /// The fix's age at [now]: from the platform time when the alert dated it, else the phone's own figure
  /// plus the time since the alert (see [AlertFix.ageAt]).
  factory SosFixText.of(Alert alert, AlertFix fix, DateTime now) {
    final age = fix.ageAt(now, alertCreatedAt: alert.createdAt) ?? Duration.zero;
    final minutes = age.inMinutes < 1 ? 1 : age.inMinutes;
    // Hours round DOWN, and the line says «more than» (Arabic Bureau, #743): 3 h 59 reads
    // "more than 3 hours", which is true for every minute of that hour and never overstates how
    // fresh the place is.
    final floored = age.inMinutes ~/ 60;
    final hours = floored < 1 ? 1 : floored;
    return SosFixText._(ageMinutes: minutes, ageHours: hours, underAnHour: age.inMinutes < 60);
  }

  /// The **notification body**: that a location exists, how old it is, and that a tap shows it. No
  /// coordinates — a lock screen is for anyone to read (#672 UI/UX review, #410's reason).
  String notificationBody(AppLocalizations l10n) =>
      underAnHour ? l10n.alertSosLocationMinutes(ageMinutes) : l10n.alertSosLocationHours(ageHours);

  /// The **detail's location line**, the Arabic Bureau's sentence: the coordinates and the age, in the
  /// alert the parent opened deliberately. [coords] must already be isolated (see [AlertFix.isolatedCoords]).
  String locationLine(AppLocalizations l10n, String coords) =>
      underAnHour ? l10n.alertSosWhereMinutes(ageMinutes, coords) : l10n.alertSosWhereHours(ageHours, coords);

  /// "accurate to about 20 m", or null when the fix carries no accuracy.
  String? accuracyClause(AppLocalizations l10n, AlertFix fix) {
    final accuracy = fix.accuracyM;
    if (accuracy == null) return null;
    final metres = accuracy.round();
    return l10n.alertLocationAccuracy(metres < 1 ? 1 : metres);
  }

  /// The map pin's caption: the category title (already translated) and the age.
  ///
  /// Hours read "about 2 hours": the age rounds **up** everywhere (a parent must never be told a fix is
  /// fresher than it is), so the pin says "more than" too — otherwise the same fix reads «قبل ساعتين» on the
  /// pin and «قبل نحو ساعتين» in the detail beside it (Arabic Bureau, #743 second review).
  String pinCaption(AppLocalizations l10n, String title) {
    final age = underAnHour ? l10n.relativeMinutesAgo(ageMinutes) : l10n.relativeOverHoursAgo(ageHours);
    return '$title · $age';
  }
}
