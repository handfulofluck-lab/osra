import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/children/command_messages.dart';
import 'package:familyshield_parent/api/permission_errors.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #419 / #424: the map's marker sheet and geofence dialog in Arabic. The screen row in
/// localization_test.dart renders the app bar only; these render the strings a parent reads after
/// tapping a marker or "add".

const child = Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013);
const device = Device(
  id: 'dev-1',
  childId: 'child-1',
  platform: 'android',
  model: 'Pixel 7',
  osVersion: '14',
  status: 'online',
  batteryPct: 80,
);

void main() {
  final ar = lookupAppLocalizations(const Locale('ar'));

  Future<FakeApiClient> pumpArabic(WidgetTester tester, Widget body) async {
    final api = FakeApiClient(standardRoutes());
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(Scaffold(body: body), locale: const Locale('ar'), textDirection: TextDirection.rtl),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('the marker sheet reads in Arabic, its date included', (tester) async {
    final ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5, timestamp: DateTime.utc(2026, 10, 27, 9, 30));
    await pumpArabic(tester, ChildMapSheet(child: child, ping: ping, device: device));
    expect(find.text(ar.familyMapRing), findsOneWidget);
    expect(find.text(ar.familyMapLock), findsOneWidget);
    expect(find.text(ar.familyMapBattery(80)), findsOneWidget);
    // The date is formatted in the parent's language like every other screen's (context.localeName),
    // not in English inside an Arabic sentence.
    expect(find.textContaining('أكتوبر'), findsOneWidget);
    expect(find.textContaining('Oct'), findsNothing);
  });

  testWidgets('a ping with no time says unknown in Arabic', (tester) async {
    const ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5);
    await pumpArabic(tester, const ChildMapSheet(child: child, ping: ping, device: device));
    expect(find.text(ar.familyMapLastUpdate(ar.familyMapLastUpdateUnknown)), findsOneWidget);
  });

  for (final (command, label) in [('ring', 'رنين الجهاز'), ('lock', 'قفل الجهاز')]) {
    testWidgets('$command: the button sends $command and the snackbar names the same command', (tester) async {
      const ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5);
      final api = await pumpArabic(tester, const ChildMapSheet(child: child, ping: ping, device: device));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(api.requests.where((r) => r.method == 'POST').map((r) => (r.data as Map)['command']), [command]);
      final queued = command == 'lock' ? ar.familyMapLockQueued('Pixel 7') : ar.familyMapRingQueued('Pixel 7');
      expect(find.text(queued), findsOneWidget);
    });
  }

  // ADR-0034 decision 3 / #221: the server refuses up front when the phone's own report says the
  // feature is not_supported. The map used to answer "queued" to those, so a parent whose ring was
  // refused was told it had been sent. The literal is pinned, not the getter: a row comparing the
  // screen to the value that feeds it passes whatever the ARB says (#429).
  testWidgets('a not_supported refusal reads as unavailable, never as queued', (tester) async {
    const ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5);
    final routes = standardRoutes()
      ..['POST /v1/devices/dev-1/command'] = (_) => {'status': 'failed', 'reason': 'not_supported'};
    final api = FakeApiClient(routes);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        const Scaffold(body: ChildMapSheet(child: child, ping: ping, device: device)),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('رنين الجهاز'));
    await tester.pumpAndSettle();
    expect(api.requests.where((r) => r.method == 'POST').length, 1);
    expect(
      find.text('«رن» غير متاح على Pixel 7: لا يستطيع هذا الهاتف أو إصدار التطبيق تنفيذه، لذلك لم يُرسل شيء.'),
      findsOneWidget,
      reason: 'the refusal must be the mapped sentence, not the raw reason or a "queued" claim',
    );
    // A second SnackBar waits in the queue behind the first, so let the refusal time out before
    // asking whether a "queued" message followed it. Without this, F4 (refusal shown but no
    // `return`, so both are queued) survives the row — Claude's planted fault, 7/7 green.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('أُرسل أمر الرنين إلى Pixel 7 — ولم يؤكّده الجهاز بعد.'), findsNothing,
        reason: 'a refused command is not queued');
  });

  test('commandRefusalText maps not_supported and still falls back to the raw code', () {
    expect(commandRefusalText(ar, 'ring', 'Pixel 7', 'not_supported'),
        '«رن» غير متاح على Pixel 7: لا يستطيع هذا الهاتف أو إصدار التطبيق تنفيذه، لذلك لم يُرسل شيء.');
    expect(commandRefusalText(ar, 'ring', 'Pixel 7', 'something_new'), contains('something_new'),
        reason: 'an unknown code stays visible rather than becoming a vague failure');
  });

  // #434: an HTTP error is a different vocabulary from a `reason`. A known cause becomes a sentence
  // the parent can act on; an unknown one stays verbatim, because hiding it is the "queued" mistake
  // in another costume. Literals again, not getters (#429).
  testWidgets('a 403 on ring reads as a permission sentence, not the raw code', (tester) async {
    const ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5);
    final routes = standardRoutes()
      ..['POST /v1/devices/dev-1/command'] =
          (_) => const FakeHttpError(403, {'error': 'permission_required', 'permission': 'devices'});
    final api = FakeApiClient(routes);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        const Scaffold(body: ChildMapSheet(child: child, ping: ping, device: device)),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('رنين الجهاز'));
    await tester.pumpAndSettle();
    expect(find.text('لا تملك صلاحية إرسال «رن» إلى Pixel 7. يمكن لمالك العائلة منحك حق الوصول.'),
        findsOneWidget);
    expect(find.textContaining('permission_required'), findsNothing,
        reason: 'a mapped cause is not shown as a code');
  });

  test('commandErrorText keys on the shapes the routes send, and keeps the rest verbatim', () {
    final options = RequestOptions(path: '/v1/devices/dev-1/command');
    DioException http(int status, Map<String, dynamic> body) => DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: status, data: body),
          type: DioExceptionType.badResponse,
        );

    // the guard's real body: 403 permission_required, permission named on the wire, not in the sentence
    expect(
      commandErrorText(ar, 'ring', 'Pixel 7',
          http(403, {'error': 'permission_required', 'permission': 'devices'})),
      'لا تملك صلاحية إرسال «رن» إلى Pixel 7. يمكن لمالك العائلة منحك حق الوصول.',
    );
    // @fastify/rate-limit's own body — keyed on the status, not on a string it never sends
    expect(
      commandErrorText(ar, 'ring', 'Pixel 7',
          http(429, {'statusCode': 429, 'error': 'Too Many Requests', 'message': 'Rate limit exceeded, retry in 1 minute'})),
      'لم يُرسل «رن» إلى Pixel 7: طلبات كثيرة الآن. حاول مرة أخرى بعد دقيقة.',
    );
    // a reason the agent would have used keeps the same sentence as a 200 refusal
    expect(commandErrorText(ar, 'ring', 'Pixel 7', 'not_supported'),
        '«رن» غير متاح على Pixel 7: لا يستطيع هذا الهاتف أو إصدار التطبيق تنفيذه، لذلك لم يُرسل شيء.');
    // anything else stays visible
    expect(commandErrorText(ar, 'ring', 'Pixel 7', 'some_new_code'), contains('some_new_code'),
        reason: 'an unknown code must stay visible rather than becoming a vague failure');
  });

  testWidgets('a 429 on lock reads as "try again in a minute", not as Too Many Requests', (tester) async {
    const ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5);
    final routes = standardRoutes()
      ..['POST /v1/devices/dev-1/command'] = (_) => const FakeHttpError(
          429, {'statusCode': 429, 'error': 'Too Many Requests', 'message': 'Rate limit exceeded, retry in 1 minute'});
    final api = FakeApiClient(routes);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        const Scaffold(body: ChildMapSheet(child: child, ping: ping, device: device)),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('قفل الجهاز'));
    await tester.pumpAndSettle();
    expect(find.text('لم يُرسل «قفل» إلى Pixel 7: طلبات كثيرة الآن. حاول مرة أخرى بعد دقيقة.'), findsOneWidget);
    expect(find.textContaining('Too Many Requests'), findsNothing);
  });

  testWidgets('a refused geofence reads as the owner sentence, not permission_required', (tester) async {
    final routes = standardRoutes()
      ..['POST /v1/location/geofences'] =
          (_) => const FakeHttpError(403, {'error': 'permission_required', 'permission': 'location'});
    final api = FakeApiClient(routes);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        const Scaffold(body: GeofenceCreateDialog(children: [child], initialCenter: LatLng(25.3, 51.5))),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'المدرسة');
    await tester.tap(find.text(ar.familyMapCreate));
    await tester.pumpAndSettle();
    expect(find.text('يمكن لمالك العائلة منحك حق الوصول إلى هذا.'), findsOneWidget);
    expect(find.textContaining('permission_required'), findsNothing);
  });

  // #437 part A: a write refused for consent is not a command refusal — the sentence must not name a
  // command, and it must send the parent to the page that can explain it. Literals again (#429).
  testWidgets('a geofence write refused for consent says why, not the raw 428', (tester) async {
    final routes = standardRoutes()
      ..['POST /v1/location/geofences'] =
          (_) => const FakeHttpError(428, {'error': 'parental_consent_required', 'childId': 'child-1'});
    final api = FakeApiClient(routes);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        const Scaffold(body: GeofenceCreateDialog(children: [child], initialCenter: LatLng(25.3, 51.5))),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'المدرسة');
    await tester.tap(find.text(ar.familyMapCreate));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'لم يُحفظ هذا التغيير: لا توجد موافقة سارية لهذا الطفل، لذلك المراقبة متوقفة. افتح «موافقة الوالدين» في صفحة الطفل لمعرفة السبب.'),
        findsOneWidget);
    expect(find.textContaining('parental_consent_required'), findsNothing);
  });

  test('readErrorText maps both consent codes and leaves a bare 428 to the screen', () {
    final options = RequestOptions(path: '/v1/rules/child-1');
    DioException http(int status, Map<String, dynamic> body) => DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: status, data: body),
          type: DioExceptionType.badResponse,
        );

    expect(
        readErrorText(ar, http(428, {'error': 'parental_consent_required', 'childId': 'child-1'}), () => 'fallback'),
        'لم يُحفظ هذا التغيير: لا توجد موافقة سارية لهذا الطفل، لذلك المراقبة متوقفة. افتح «موافقة الوالدين» في صفحة الطفل لمعرفة السبب.');
    expect(
        readErrorText(ar, http(428, {'error': 'consent_jurisdiction_mismatch'}), () => 'fallback'),
        'لم يُحفظ هذا التغيير: مُنحت موافقة هذا الطفل لمنطقة تختلف عن منطقة عائلتك. افتح «موافقة الوالدين» في صفحة الطفل للتفاصيل.');
    expect(readErrorText(ar, http(428, {'error': 'something_else'}), () => 'fallback'), 'fallback',
        reason: "a bare 428 with an unknown code stays the screen's message, not an invented sentence");
  });

  testWidgets('the add-geofence dialog reads in Arabic and asks for a label in Arabic', (tester) async {
    await pumpArabic(
      tester,
      const GeofenceCreateDialog(children: [child], initialCenter: LatLng(25.3, 51.5)),
    );
    expect(find.text(ar.familyMapAddGeofence), findsOneWidget);
    expect(find.text(ar.familyMapLabelField), findsOneWidget);
    expect(find.text(ar.familyMapRadius(250)), findsOneWidget);
    expect(find.text(ar.cancel), findsOneWidget);
    await tester.tap(find.text(ar.familyMapCreate));
    await tester.pumpAndSettle();
    expect(find.text(ar.familyMapEnterLabel), findsOneWidget);
  });
}
