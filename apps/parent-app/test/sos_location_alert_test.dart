import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart' show MapFocus, initialCameraFor;
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

/// Issue #672 (Flip4, scenario run 1 on #665): the SOS reached the parent's list in 5.2 s with metadata
/// `{deviceId}` and no place in the body, while a 13-minute-old fix was on the phone. A parent who gets an
/// SOS needs "where" in the same notification.
///
/// **The push payload still carries no text.** #410/#395 made every parent push a data-only wake
/// (`{ "w": "1" }`), and the visible row is built here, on the device, from `/v1/alerts` — so this is where
/// the sentence belongs, in the family's language, and it is the only place it can live without undoing
/// those decisions.
///
/// Mutants, one row each: use `alertPushBodyGeneric` for `sos` too → [a SOS with a fix says where and how
/// old it is]; ignore the category and add the sentence to every alert → [another category with a point
/// keeps the generic body]; use the phone's `ageSeconds` alone as "now" → [the age grows with the time
/// since the alert]; drop the Arabic override → [Arabic says it in Arabic].
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ar = lookupAppLocalizations(const Locale('ar'));

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

  final fixMeta = <String, dynamic>{
    'deviceId': 'dev-1',
    'lat': 25.2769,
    'lng': 51.5211,
    'accuracyM': 12.0,
    'takenAt': '2026-11-13T19:12:52.000Z',
    'ageSeconds': 180,
  };

  group('AlertFix', () {
    test('reads a stored fix', () {
      final fix = AlertFix.fromMetadata(fixMeta)!;
      expect(fix.lat, 25.2769);
      expect(fix.lng, 51.5211);
      expect(fix.accuracyM, 12.0);
      expect(fix.age, const Duration(seconds: 180));
      expect(fix.coordsText, '25.276900, 51.521100');
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
      final fix = AlertFix.fromMetadata(fixMeta)!;
      final now = DateTime.utc(2026, 11, 13, 19, 25, 52); // ten minutes after the fix was taken
      expect(fix.ageAt(now, alertCreatedAt: DateTime.utc(2026, 11, 13, 19, 15, 52)), const Duration(minutes: 13));
    });

    test('and from the phone-reported age when it has only that', () {
      final fix = AlertFix.fromMetadata({'lat': 25.2769, 'lng': 51.5211, 'ageSeconds': 60})!;
      final now = DateTime.utc(2026, 11, 13, 19, 25, 52);
      expect(fix.ageAt(now, alertCreatedAt: DateTime.utc(2026, 11, 13, 19, 15, 52)), const Duration(minutes: 10, seconds: 60));
    });
  });

  group('the SOS notification says where', () {
    test('a SOS with a fix says where and how old it is', () {
      final visible = VisibleAlert.from(
        sos(metadata: fixMeta),
        l10n: en,
        isEnglish: true,
        now: DateTime.utc(2026, 11, 13, 19, 15, 52),
      );
      expect(visible.body, contains('near 25.276900, 51.521100'));
      expect(visible.body, contains('3 min ago'));
      expect(visible.body, isNot(en.alertPushBodyGeneric));
    });

    test('the age grows with the time since the alert', () {
      // Ten minutes later the notification must not still say "3 min ago".
      final visible = VisibleAlert.from(
        sos(metadata: fixMeta),
        l10n: en,
        isEnglish: true,
        now: DateTime.utc(2026, 11, 13, 19, 25, 52),
      );
      expect(visible.body, contains('13 min ago'));
    });

    test('an hour-old fix is labelled in hours', () {
      final old = Map<String, dynamic>.from(fixMeta)..['takenAt'] = '2026-11-13T18:15:52.000Z';
      final visible = VisibleAlert.from(
        sos(metadata: old),
        l10n: en,
        isEnglish: true,
        now: DateTime.utc(2026, 11, 13, 19, 15, 52),
      );
      expect(visible.body, contains('1 h ago'));
    });

    test('a SOS without a fix keeps the generic body and is still shown', () {
      final visible = VisibleAlert.from(
        sos(metadata: const {'deviceId': 'dev-1'}),
        l10n: en,
        isEnglish: true,
        now: DateTime.utc(2026, 11, 13, 19, 15, 52),
      );
      expect(visible.body, en.alertPushBodyGeneric);
      expect(visible.title, en.alertTitleFor('sos', 'SOS from SM-F721B', isEnglish: true));
    });

    test('another category with a point keeps the generic body', () {
      final visible = VisibleAlert.from(
        sos(metadata: fixMeta, category: 'geofence'),
        l10n: en,
        isEnglish: true,
        now: DateTime.utc(2026, 11, 13, 19, 15, 52),
      );
      expect(visible.body, en.alertPushBodyGeneric);
    });

    test('Arabic says it in Arabic', () {
      final visible = VisibleAlert.from(
        sos(metadata: fixMeta),
        l10n: ar,
        isEnglish: false,
        now: DateTime.utc(2026, 11, 13, 19, 15, 52),
      );
      expect(visible.body, contains('استغاثة'));
      expect(visible.body, contains('25.276900, 51.521100'));
      expect(visible.body, contains('قبل'));
    });
  });

  group('the map opens on the alert fix (#672)', () {
    test('a focus is the camera, close in', () {
      final focus = MapFocus.fromFix(
        AlertFix.fromMetadata(fixMeta)!,
      );
      final camera = initialCameraFor(focus, const LatLng(1, 2));
      expect(camera.target.latitude, closeTo(25.2769, 1e-9));
      expect(camera.target.longitude, closeTo(51.5211, 1e-9));
      expect(camera.zoom, 16);
    });

    test('without a focus the tab keeps its own rule', () {
      expect(initialCameraFor(null, const LatLng(1, 2)).target, const LatLng(1, 2));
      expect(initialCameraFor(null, null).zoom, 2);
    });
  });
}
