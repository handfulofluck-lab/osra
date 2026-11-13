import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart' show MapFocus, initialCameraFor;
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:familyshield_parent/push/sos_fix_text.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

/// Issue #672, second head: the two Bureaus' reviews and Fable's privacy points, as rows.
///
/// **UI/UX:** the lock screen says a location exists and how old it is — **no coordinates**; the numbers
/// live in the alert's detail, where "Copy coordinates" puts five decimals on the clipboard.
/// **Arabic Language Bureau:** one whole line per plural case, the coordinates isolated with LRI U+2066 …
/// PDI U+2069 in code, and hours rounded **up** («about 2 hours» for 119 minutes).
///
/// The isolate is the safety bug this head fixes: in a right-to-left line `25.276900, 51.521100` used to
/// draw longitude first, so a parent reading it aloud reached another country.
///
/// Mutants, one row each: remove the LRI/PDI wrap in [AlertFix.isolatedCoords] → [the Arabic location line
/// isolates the coordinates]; stop rounding hours up → [119 minutes reads as about 2 hours, not 1]; put the
/// coordinates back in the notification body → [the notification body carries no coordinates]; use
/// `age.inHours` in [SosFixText] → the same hours row; six decimals in [AlertFix.copyText] →
/// [Copy coordinates puts five decimals on the clipboard].
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ar = lookupAppLocalizations(const Locale('ar'));

  /// The alert's own time; every row below measures the fix against it unless it says otherwise.
  final alertAt = DateTime.utc(2026, 11, 13, 19, 15, 52);

  Alert sos({
    Map<String, dynamic> metadata = const {},
    String category = 'sos',
    String? at = '2026-11-13T19:15:52.000Z',
  }) =>
      Alert.fromJson({
        'id': 'a-sos',
        'severity': 'critical',
        'category': category,
        'title': 'SOS from SM-F721B',
        'body': 'Your child pressed the SOS button',
        'metadata': metadata,
        'createdAt': at,
      });

  Map<String, dynamic> fixAgo(int minutes) => {
        'deviceId': 'dev-1',
        'lat': 25.2769,
        'lng': 51.5211,
        'accuracyM': 20.0,
        'takenAt': alertAt.subtract(Duration(minutes: minutes)).toIso8601String(),
        'ageSeconds': minutes * 60,
      };

  group('AlertFix', () {
    test('reads a stored fix', () {
      final fix = AlertFix.fromMetadata(fixAgo(3))!;
      expect(fix.lat, 25.2769);
      expect(fix.lng, 51.5211);
      expect(fix.accuracyM, 20.0);
      expect(fix.coordsText, '25.276900, 51.521100');
    });

    test('Copy coordinates puts five decimals on the clipboard', () {
      // One metre is five decimals; six is noise a parent reading it aloud cannot use (UI/UX review).
      expect(AlertFix.fromMetadata(fixAgo(3))!.copyText, '25.27690, 51.52110');
    });

    test('the coordinates are isolated with LRI U+2066 and PDI U+2069, for every language', () {
      final fix = AlertFix.fromMetadata(fixAgo(3))!;
      expect(fix.isolatedCoords, '\u206625.276900, 51.521100\u2069');
      expect(fix.isolatedCoords.codeUnits.first, 0x2066);
      expect(fix.isolatedCoords.codeUnits.last, 0x2069);
      // The marks are direction, not words: they are added in code, never in the ARB.
      expect(ar.alertSosWhereMinutes(3, 'X'), isNot(contains('\u2066')));
    });

    test('a half fix or an impossible one is no fix', () {
      expect(AlertFix.fromMetadata({'lat': 25.2769}), isNull);
      expect(AlertFix.fromMetadata({'lng': 51.5211}), isNull);
      expect(AlertFix.fromMetadata({'lat': 91.0, 'lng': 51.5211}), isNull);
      expect(AlertFix.fromMetadata({'lat': 25.2769, 'lng': -181.0}), isNull);
      expect(AlertFix.fromMetadata({'lat': 'north', 'lng': 'east'}), isNull);
      expect(AlertFix.fromMetadata({'deviceId': 'dev-1'}), isNull);
    });

    test('the age is measured from the fix time when the alert has one', () {
      final fix = AlertFix.fromMetadata(fixAgo(3))!;
      final now = DateTime.utc(2026, 11, 13, 19, 25, 52); // ten minutes after the fix was taken
      expect(fix.ageAt(now, alertCreatedAt: alertAt), const Duration(minutes: 13));
    });

    test('and from the phone-reported age when it has only that', () {
      final fix = AlertFix.fromMetadata({'lat': 25.2769, 'lng': 51.5211, 'ageSeconds': 60})!;
      final now = DateTime.utc(2026, 11, 13, 19, 25, 52);
      expect(fix.ageAt(now, alertCreatedAt: alertAt), const Duration(minutes: 10, seconds: 60));
    });
  });

  group('the notification body', () {
    test('says a place exists and how old it is, and carries no coordinates', () {
      final visible = VisibleAlert.from(sos(metadata: fixAgo(3)), l10n: en, isEnglish: true, now: alertAt);
      expect(visible.body, 'Location from 3 min ago. Tap to see it on the map.');
      expect(visible.body, isNot(contains('25.276')));
      expect(visible.body, isNot(contains('51.521')));
    });

    test('the age grows with the time since the alert', () {
      final visible = VisibleAlert.from(
        sos(metadata: fixAgo(3)),
        l10n: en,
        isEnglish: true,
        now: alertAt.add(const Duration(minutes: 10)),
      );
      expect(visible.body, 'Location from 13 min ago. Tap to see it on the map.');
    });

    test('119 minutes reads as about 2 hours, not 1', () {
      // Rounding up is the safe direction: a parent must never be told a fix is fresher than it is.
      final visible = VisibleAlert.from(sos(metadata: fixAgo(119)), l10n: en, isEnglish: true, now: alertAt);
      expect(visible.body, 'Location from about 2 hours ago. Tap to see it on the map.');
    });

    test('one hour reads as about 1 hour', () {
      expect(
        VisibleAlert.from(sos(metadata: fixAgo(60)), l10n: en, isEnglish: true, now: alertAt).body,
        'Location from about 1 hour ago. Tap to see it on the map.',
      );
    });

    test('a SOS without a fix keeps the generic body, and is still shown', () {
      final visible = VisibleAlert.from(
        sos(metadata: const {'deviceId': 'dev-1'}),
        l10n: en,
        isEnglish: true,
        now: alertAt,
      );
      expect(visible.body, en.alertPushBodyGeneric);
      expect(visible.title, en.alertTitleFor('sos', 'SOS from SM-F721B', isEnglish: true));
    });

    test('another category with a point keeps the generic body', () {
      final visible = VisibleAlert.from(
        sos(metadata: fixAgo(3), category: 'geofence'),
        l10n: en,
        isEnglish: true,
        now: alertAt,
      );
      expect(visible.body, en.alertPushBodyGeneric);
    });

    test('Arabic says it in Arabic, whole line per plural case', () {
      // Pinned whole, per the Arabic Language Bureau: 1, 2, 3 and 11 minutes, the four CLDR categories
      // this app can meet. A change to any of these four is a decision, not a translation tweak.
      String body(int minutes) =>
          VisibleAlert.from(sos(metadata: fixAgo(minutes)), l10n: ar, isEnglish: false, now: alertAt).body;

      expect(body(1), 'سُجّل آخر موقع قبل دقيقة. اضغط لعرضه.');
      expect(body(2), 'سُجّل آخر موقع قبل دقيقتين. اضغط لعرضه.');
      expect(body(3), 'سُجّل آخر موقع قبل 3 دقائق. اضغط لعرضه.');
      expect(body(11), 'سُجّل آخر موقع قبل 11 دقيقة. اضغط لعرضه.');
      // 61 minutes is the hours branch, and it must say «نحو» (about) like the detail beside it.
      expect(body(61), 'سُجّل آخر موقع قبل نحو ساعتين. اضغط لعرضه.');
      expect(body(3), isNot(contains('25.276')));
    });
  });

  group('the detail line', () {
    test('the Arabic location line isolates the coordinates', () {
      final alert = sos(metadata: fixAgo(3));
      final line = SosFixText.of(alert, alert.location!, alertAt).locationLine(ar, alert.location!.isolatedCoords);
      // The row the Arabic Bureau asked for, codepoint by codepoint.
      expect(line, contains('\u206625.276900, 51.521100\u2069'));
      expect(line.codeUnitAt(line.indexOf('\u2066')), 0x2066);
      expect(line, contains('آخر موقع'));
    });

    test('the English location line names the place and the age', () {
      final alert = sos(metadata: fixAgo(3));
      final line = SosFixText.of(alert, alert.location!, alertAt).locationLine(en, alert.location!.isolatedCoords);
      expect(line, 'Last location: \u206625.276900, 51.521100\u2069, 3 min ago');
    });

    test('the accuracy clause is said only when the fix carries one', () {
      final withAccuracy = sos(metadata: fixAgo(3));
      expect(
        SosFixText.of(withAccuracy, withAccuracy.location!, alertAt).accuracyClause(en, withAccuracy.location!),
        'accurate to about 20 m',
      );
      final without = sos(metadata: fixAgo(3)..remove('accuracyM'));
      expect(SosFixText.of(without, without.location!, alertAt).accuracyClause(en, without.location!), isNull);
    });

    test('the pin caption says what it is and how old', () {
      final alert = sos(metadata: fixAgo(3));
      final caption = SosFixText.of(alert, alert.location!, alertAt).pinCaption(en, 'SOS');
      expect(caption, 'SOS · 3m ago');
    });
  });

  group('the map opens on the alert fix (#672)', () {
    test('a focus is the camera, close in, with the accuracy it was given', () {
      final focus = MapFocus.fromFix(AlertFix.fromMetadata(fixAgo(3))!, label: 'SOS · 3m ago');
      final camera = initialCameraFor(focus, const LatLng(1, 2));
      expect(camera.target.latitude, closeTo(25.2769, 1e-9));
      expect(camera.target.longitude, closeTo(51.5211, 1e-9));
      expect(camera.zoom, 16);
      expect(focus.label, 'SOS · 3m ago');
      expect(focus.accuracyM, 20.0);
    });

    test('without a focus the tab keeps its own rule', () {
      expect(initialCameraFor(null, const LatLng(1, 2)).target, const LatLng(1, 2));
      expect(initialCameraFor(null, null).zoom, 2);
    });
  });
}
