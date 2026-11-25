import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/change_device_pin.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations_en.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #1108: "Change device PIN" in the parent app (Ahmed's R3 ruling on the issue).
///
/// - the phone's PIN rules are checked before the parent types a password;
/// - the request carries the PIN and the proof, never anything to read back;
/// - a wrong password says so, and the PIN is not changed;
/// - iPhones do not get the button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = AppLocalizationsEn();

  const android = Device(
    id: 'dev-1',
    childId: 'child-1',
    platform: 'android',
    model: 'Galaxy Z Flip4',
    osVersion: '14',
    status: 'online',
    batteryPct: 80,
  );
  const iphone = Device(
    id: 'dev-2',
    childId: 'child-1',
    platform: 'ios',
    model: 'iPhone 13',
    osVersion: '18',
    status: 'online',
    batteryPct: 80,
  );

  test('the phone\'s PIN rules, including Arabic digits', () {
    expect(devicePinProblem('4729'), isNull);
    expect(devicePinProblem('٤٧٢٩'), isNull);
    expect(devicePinProblem('58392176'), isNull);
    expect(devicePinProblem('472'), DevicePinProblem.tooShort);
    expect(devicePinProblem('472947294'), DevicePinProblem.tooLong);
    expect(devicePinProblem('47a9'), DevicePinProblem.notDigits);
    expect(devicePinProblem('7777'), DevicePinProblem.weak);
    expect(devicePinProblem('1234'), DevicePinProblem.weak);
    expect(devicePinProblem('654321'), DevicePinProblem.weak);
  });

  test('only Android phones can have their PIN changed from here', () {
    expect(canChangeDevicePin(android), isTrue);
    expect(canChangeDevicePin(iphone), isFalse);
  });

  test('the API\'s refusals become the parent\'s words', () {
    DioException err(int status, Object body) => DioException(
          requestOptions: RequestOptions(path: '/v1/devices/dev-1/parent-pin'),
          response: Response(requestOptions: RequestOptions(), statusCode: status, data: body),
        );
    const m = 'Galaxy Z Flip4';
    final type = l10n.commandSetParentPin;
    expect(changeDevicePinErrorText(l10n, m, err(401, {'error': 'reauth_failed'})), l10n.changeDevicePinWrongProof);
    expect(changeDevicePinErrorText(l10n, m, err(429, {'error': 'pin_change_limit'})), l10n.changeDevicePinLimit);
    expect(changeDevicePinErrorText(l10n, m, err(409, {'error': 'command_not_supported'})), l10n.changeDevicePinNotSupported);
    expect(changeDevicePinErrorText(l10n, m, err(400, {'error': 'pin_weak'})), l10n.changeDevicePinWeak);
    // F2: everything else reads as it does for any command.
    expect(changeDevicePinErrorText(l10n, m, err(429, {'error': 'Too Many Requests'})), l10n.commandErrorRateLimited(type, m));
    expect(changeDevicePinErrorText(l10n, m, err(403, {'error': 'permission_required', 'permission': 'devices'})), l10n.commandErrorForbidden(type, m));
    expect(changeDevicePinErrorText(l10n, m, err(428, {'error': 'parental_consent_required'})), l10n.commandErrorConsentWithdrawn(type, m));
  });

  test('F1: the audit alert reads in the parent\'s language, never the server\'s English', () async {
    final ar = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(ar.alertCategory('device_pin_changed'), ar.alertCategoryDevicePinChanged);
    expect(ar.alertCategory('device_pin_changed'), isNot('device_pin_changed'));
    expect(ar.alertTitleFor('device_pin_changed', 'Device PIN changed', isEnglish: false), ar.alertTitleDevicePinChanged);
    final json = <String, dynamic>{
      'id': 'al-1',
      'childId': 'child-1',
      'severity': 'warning',
      'category': 'device_pin_changed',
      'title': 'Device PIN changed',
      'body': 'Karim set a new OSRA PIN on Galaxy Z Flip4. The old PIN no longer works once the phone receives it.',
      'metadata': {'type': 'parent_pin_changed', 'changedByName': 'Karim', 'deviceModel': 'Galaxy Z Flip4'},
      'createdAt': '2026-11-25T12:00:00Z',
      'acknowledged': false,
    };
    final alert = Alert.fromJson(json);
    final arBody = formatGeneralAlertBody(alert, l10n: ar, localeName: 'ar');
    expect(arBody, ar.alertBodyDevicePinChanged('Karim', 'Galaxy Z Flip4'));
    expect(arBody, isNot(contains('set a new')));
    final bare = Alert.fromJson({...json, 'metadata': <String, dynamic>{}});
    expect(formatGeneralAlertBody(bare, l10n: ar, localeName: 'ar'), '');
    expect(formatGeneralAlertBody(bare, l10n: l10n, localeName: 'en'), bare.body);
  });

  Future<FakeApiClient> pumpButton(WidgetTester tester, Device device, FakeRoute route) async {
    final api = FakeApiClient({'POST /v1/devices/${device.id}/parent-pin': route});
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(Scaffold(body: ChangeDevicePinButton(device: device))),
    ));
    await tester.tap(find.byKey(ValueKey('deviceAction-changePin-${device.id}')));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> fill(WidgetTester tester, {String pin = '4729', String? repeat, String password = 'pw', String code = ''}) async {
    await tester.enterText(find.byKey(const ValueKey('changePinNew')), pin);
    await tester.enterText(find.byKey(const ValueKey('changePinRepeat')), repeat ?? pin);
    await tester.enterText(find.byKey(const ValueKey('changePinPassword')), password);
    await tester.enterText(find.byKey(const ValueKey('changePinCode')), code);
    await tester.tap(find.byKey(const ValueKey('changePinSave')));
    await tester.pumpAndSettle();
  }

  testWidgets('a weak PIN, a mismatch and a missing password are refused in place, with nothing sent', (tester) async {
    final api = await pumpButton(tester, android, (_) => {'status': 'pending'});
    await fill(tester, pin: '1234');
    expect(find.text(l10n.changeDevicePinWeak), findsOneWidget);
    await fill(tester, pin: '4729', repeat: '4720');
    expect(find.text(l10n.changeDevicePinMismatch), findsOneWidget);
    await fill(tester, password: '');
    expect(find.text(l10n.changeDevicePinPasswordRequired), findsOneWidget);
    expect(api.requests, isEmpty);
  });

  testWidgets('a good PIN is sent once, with the proof and nothing else, and the parent hears it is on its way', (tester) async {
    final api = await pumpButton(tester, android, (_) => {'published': true, 'status': 'pending', 'id': 'cmd-1'});
    await fill(tester, pin: '٥٨٣٩٢١', password: 'correct horse', code: '123456');
    final calls = api.calls('POST', '/v1/devices/dev-1/parent-pin');
    expect(calls, hasLength(1));
    expect(calls.single.body, {'pin': '583921', 'password': 'correct horse', 'mfaCode': '123456'});
    expect(find.text(l10n.changeDevicePinQueued('Galaxy Z Flip4')), findsOneWidget);
  });

  testWidgets('without an authenticator code, no mfaCode field is sent', (tester) async {
    final api = await pumpButton(tester, android, (_) => {'status': 'pending'});
    await fill(tester, password: 'pw');
    expect(api.calls('POST', '/v1/devices/dev-1/parent-pin').single.body, {'pin': '4729', 'password': 'pw'});
  });

  testWidgets('a wrong password says the PIN was not changed', (tester) async {
    await pumpButton(tester, android, (_) => const FakeHttpError(401, {'error': 'reauth_failed'}));
    await fill(tester);
    expect(find.text(l10n.changeDevicePinWrongProof), findsOneWidget);
  });

  testWidgets('cancel sends nothing', (tester) async {
    final api = await pumpButton(tester, android, (_) => {'status': 'pending'});
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(api.requests, isEmpty);
    expect(find.byKey(const ValueKey('changePinNew')), findsNothing);
  });
}
