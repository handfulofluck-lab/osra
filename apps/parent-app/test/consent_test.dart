import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/consent_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  FakeApiClient consentApi(Map<String, dynamic> status, {FakeRoute? revoke}) =>
      FakeApiClient({
        ...standardRoutes(),
        'GET /v1/family/children/child-1/consent': (_) => status,
        if (revoke != null)
          'POST /v1/family/children/child-1/consent/revoke': revoke,
      });

  /// The confirmation page is deliberately long copy; a phone-sized viewport
  /// keeps most of it out of the lazily built list. Behaviour tests run tall so
  /// every control is in the tree; the 320x568 layout test scrolls instead.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget home,
    FakeApiClient api, {
    Locale locale = const Locale('en'),
    TextDirection? direction,
    bool tall = true,
  }) async {
    if (tall) useTallSurface(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home, locale: locale, textDirection: direction),
    ));
    await tester.pumpAndSettle();
  }

  String stateLabel(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('consentState'))).data!;

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  group('ConsentState derivation', () {
    final now = DateTime.utc(2026, 10, 19, 12);

    ConsentStatus status({
      bool active = false,
      String? reason,
      List<ConsentRecord> records = const [],
      ConsentRecord? consent,
    }) =>
        ConsentStatus(
          active: active,
          reason: reason,
          jurisdiction: 'US',
          records: records,
          consent: consent,
        );

    ConsentRecord record({DateTime? expiresAt, DateTime? revokedAt}) =>
        ConsentRecord(
          id: 'c1',
          childId: 'child-1',
          method: 'sms_plus',
          jurisdiction: 'US',
          grantedAt: DateTime.utc(2026, 9, 1),
          expiresAt: expiresAt,
          revokedAt: revokedAt,
        );

    test('active / expiring / expired / revoked / none / mismatch', () {
      expect(status(active: true, records: [record()]).stateAt(now),
          ConsentState.active);
      expect(
        status(
                active: true,
                records: [record(expiresAt: now.add(const Duration(days: 5)))])
            .stateAt(now),
        ConsentState.expiring,
      );
      expect(
        status(
                active: true,
                records: [record(expiresAt: now.add(const Duration(days: 30)))])
            .stateAt(now),
        ConsentState.active,
      );
      expect(
        status(records: [
          record(expiresAt: now.subtract(const Duration(days: 1)))
        ]).stateAt(now),
        ConsentState.expired,
      );
      expect(
        status(records: [
          record(revokedAt: now.subtract(const Duration(days: 2)))
        ]).stateAt(now),
        ConsentState.revoked,
      );
      expect(status(reason: 'parental_consent_required').stateAt(now),
          ConsentState.none);
      expect(
          status(reason: 'consent_jurisdiction_mismatch', records: [record()])
              .stateAt(now),
          ConsentState.jurisdictionMismatch);
    });

    test('a revoked record is still the current record for display', () {
      final parsed = ConsentStatus.fromJson({
        'active': false,
        'reason': 'parental_consent_required',
        'records': [
          {
            'id': 'c1',
            'childId': 'child-1',
            'method': 'face_match',
            'jurisdiction': 'EU',
            'grantedAt': '2026-09-01T00:00:00.000Z',
            'expiresAt': null,
            'revokedAt': '2026-10-18T00:00:00.000Z',
            'thirdPartySharing': true,
          },
        ],
      });
      expect(parsed.current?.method, 'face_match');
      expect(parsed.current?.revokedAt, isNotNull);
      expect(parsed.current?.thirdPartySharing, isTrue);
      expect(parsed.stateAt(now), ConsentState.revoked);
    });
  });

  group('ConsentScreen states', () {
    testWidgets('active record shows the fields the API really returns',
        (tester) async {
      final api = consentApi(consentStatusPayload(records: [
        consentRecordJson(
          method: 'kba',
          jurisdiction: 'US',
          grantedAt: DateTime.utc(2026, 9, 1),
          thirdPartySharing: true,
        ),
      ]));
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(stateLabel(tester), 'Active');
      expect(find.text('Knowledge-based questions'), findsOneWidget);
      expect(find.text('US'), findsOneWidget);
      expect(find.text('Consent method'), findsOneWidget);
      expect(find.text('Granted'), findsOneWidget);
      expect(find.text('No expiry'), findsOneWidget);
      expect(find.text('On'), findsOneWidget);
      expect(find.text('Not withdrawn'), findsOneWidget);
      expect(find.textContaining('2026'), findsWidgets);
      expect(find.byKey(const ValueKey('consentRevokeButton')), findsOneWidget);
      expect(api.calls('GET', '/v1/family/children/child-1/consent'),
          hasLength(1));
    });

    testWidgets(
        'expiring record names the expiry and keeps the action available',
        (tester) async {
      final api = consentApi(consentStatusPayload(records: [
        consentRecordJson(
            expiresAt: DateTime.now().add(const Duration(days: 5))),
      ]));
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(stateLabel(tester), 'Expiring soon');
      expect(find.textContaining('This record expires on'), findsOneWidget);
      expect(find.byKey(const ValueKey('consentRevokeButton')), findsOneWidget);
    });

    testWidgets(
        'expired record is reported as expired, not as a missing record',
        (tester) async {
      final api = consentApi(consentStatusPayload(
        active: false,
        reason: 'parental_consent_required',
        records: [
          consentRecordJson(
              expiresAt: DateTime.now().subtract(const Duration(days: 1)))
        ],
      ));
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(stateLabel(tester), 'Expired');
      expect(find.textContaining('This record expired on'), findsOneWidget);
      expect(find.byKey(const ValueKey('consentRevokeButton')), findsNothing);
    });

    testWidgets(
        'revoked record stays visible with its real method and withdrawal date',
        (tester) async {
      final api = consentApi(consentStatusPayload(
        active: false,
        reason: 'parental_consent_required',
        records: [
          consentRecordJson(
              method: 'credit_card', revokedAt: DateTime.utc(2026, 10, 1)),
        ],
      ));
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(stateLabel(tester), 'Withdrawn');
      expect(find.text('Credit card'), findsOneWidget);
      expect(find.textContaining('Consent was withdrawn on'), findsOneWidget);
      expect(find.text('Not withdrawn'), findsNothing);
      expect(find.byKey(const ValueKey('consentRevokeButton')), findsNothing);
      expect(find.text('There is no active consent record to withdraw.'),
          findsOneWidget);
    });

    testWidgets('no record state offers no withdrawal action', (tester) async {
      final api = consentApi(consentStatusPayload(
        active: false,
        reason: 'parental_consent_required',
      ));
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(stateLabel(tester), 'No consent record');
      expect(
        find.text(
            'No parental consent is on record for this child. Monitoring and data collection require an active record.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('consentRevokeButton')), findsNothing);
      expect(find.text('There is no active consent record to withdraw.'),
          findsOneWidget);
    });

    testWidgets('a non-owner sees why withdrawal is unavailable',
        (tester) async {
      final family = familyMeTwoChildren();
      family['parent'] = {
        ...Map<String, dynamic>.from(family['parent'] as Map),
        'role': 'co-parent'
      };
      final api = FakeApiClient({
        ...standardRoutes(familyMe: family),
        'GET /v1/family/children/child-1/consent': (_) =>
            consentStatusPayload(records: [consentRecordJson()]),
      });
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(find.text('Only the family owner can withdraw consent.'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('consentRevokeButton')), findsNothing);
    });

    testWidgets('load failure says so and retries', (tester) async {
      var attempts = 0;
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/family/children/child-1/consent': (_) {
          attempts++;
          return attempts == 1
              ? const FakeHttpError(500, {'error': 'boom'})
              : consentStatusPayload(records: [consentRecordJson()]);
        },
      });
      await pumpScreen(tester, const ConsentScreen(childId: 'child-1'), api);

      expect(
          find.text(
              'Could not load the consent record. Check your connection and try again.'),
          findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(stateLabel(tester), 'Active');
      expect(attempts, 2);
    });

    testWidgets('child detail exposes the consent entry', (tester) async {
      final api =
          consentApi(consentStatusPayload(records: [consentRecordJson()]));
      await pumpScreen(
          tester, const ChildDetailScreen(childId: 'child-1'), api);

      expect(find.byKey(const ValueKey('consentScreenTile')), findsOneWidget);
      expect(find.text('Method, dates and withdrawal'), findsOneWidget);
    });
  });

  group('withdrawal confirmation gate', () {
    testWidgets(
        'states what stops and what happens to data, and needs the exact name',
        (tester) async {
      final api =
          consentApi(consentStatusPayload(records: [consentRecordJson()]));
      ConsentRevokeResult? result;
      await pumpScreen(
        tester,
        _PushConsentRevoke(
          childName: 'Alex',
          onResult: (r) => result = r,
        ),
        api,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('What stops immediately'), findsOneWidget);
      expect(
          find.text('What happens to data already collected'), findsOneWidget);
      expect(find.textContaining('New data collection stops'), findsOneWidget);
      expect(find.textContaining('Safety alerts stop'), findsOneWidget);
      expect(find.textContaining('Nothing is deleted or anonymised now'),
          findsOneWidget);
      expect(
          find.textContaining('retention job after 90 days'), findsOneWidget);

      FilledButton confirm() => tester.widget<FilledButton>(
          find.byKey(const ValueKey('consentRevokeConfirm')));
      expect(confirm().onPressed, isNull);

      await tester.enterText(
          find.byKey(const ValueKey('consentRevokeName')), 'alex');
      await tester.pump();
      expect(confirm().onPressed, isNull);
      expect(
          find.byKey(const ValueKey('consentRevokeMismatch')), findsOneWidget);
      expect(api.calls('POST', '/v1/family/children/child-1/consent/revoke'),
          isEmpty);

      await tester.enterText(
          find.byKey(const ValueKey('consentRevokeName')), 'Alex');
      await tester.pump();
      expect(confirm().onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('consentRevokeConfirm')));
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/family/children/child-1/consent/revoke'),
          hasLength(1));
      expect(result?.count, 1);
    });

    testWidgets('a 403 does not claim success and keeps the form',
        (tester) async {
      final api = consentApi(
        consentStatusPayload(records: [consentRecordJson()]),
        revoke: (_) => const FakeHttpError(403, {'error': 'owner_required'}),
      );
      ConsentRevokeResult? result;
      await pumpScreen(
        tester,
        _PushConsentRevoke(childName: 'Alex', onResult: (r) => result = r),
        api,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('consentRevokeName')), 'Alex');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('consentRevokeConfirm')));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(
          find.byKey(const ValueKey('consentRevokeConfirm')), findsOneWidget);
      expect(
          find.text(
              'Only the family owner can withdraw consent. Nothing was changed.'),
          findsOneWidget);
    });

    testWidgets('a transport failure says nothing changed', (tester) async {
      final api = consentApi(
        consentStatusPayload(records: [consentRecordJson()]),
        revoke: (_) => const FakeNetworkError(),
      );
      ConsentRevokeResult? result;
      await pumpScreen(
        tester,
        _PushConsentRevoke(childName: 'Alex', onResult: (r) => result = r),
        api,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('consentRevokeName')), 'Alex');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('consentRevokeConfirm')));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(
        find.text(
            'Could not withdraw consent. Nothing was changed. Check your connection and try again.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('Arabic RTL at 320x568: status and confirmation do not overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final api = consentApi(consentStatusPayload(records: [
      consentRecordJson(
        method: 'kba',
        expiresAt: DateTime.now().add(const Duration(days: 5)),
        thirdPartySharing: true,
      ),
    ]));
    await pumpScreen(
      tester,
      const ConsentScreen(childId: 'child-1'),
      api,
      locale: const Locale('ar'),
      direction: TextDirection.rtl,
      tall: false,
    );

    expect(find.text('موافقة الوالدين'), findsOneWidget);
    expect(stateLabel(tester), 'تنتهي قريبًا');
    expect(find.text('أسئلة معرفية'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byType(Scaffold))),
        TextDirection.rtl);
    expect(drainExceptions(tester), isEmpty);

    await pumpScreen(
      tester,
      const ConsentRevokeScreen(childId: 'child-1', childName: 'أليكس'),
      api,
      locale: const Locale('ar'),
      direction: TextDirection.rtl,
      tall: false,
    );

    expect(find.text('سحب الموافقة؟'), findsOneWidget);
    expect(find.textContaining('يتوقف جمع البيانات الجديد'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byType(Scaffold))),
        TextDirection.rtl);
    expect(drainExceptions(tester), isEmpty);

    // The data-handling copy sits below the fold on a 568 px screen; scroll to
    // it so the overflow check covers the whole confirmation page.
    await tester.scrollUntilVisible(
        find.textContaining('لا يُحذف أي شيء'), 200);
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يُحذف أي شيء'), findsOneWidget);
    expect(drainExceptions(tester), isEmpty);
  });
}

/// Hosts [ConsentRevokeScreen] behind a navigator push so the test can read
/// the result the screen pops with.
class _PushConsentRevoke extends StatelessWidget {
  final String childName;
  final ValueChanged<ConsentRevokeResult?> onResult;

  const _PushConsentRevoke({required this.childName, required this.onResult});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final result =
                  await Navigator.of(context).push<ConsentRevokeResult>(
                MaterialPageRoute(
                  builder: (_) => ConsentRevokeScreen(
                      childId: 'child-1', childName: childName),
                ),
              );
              onResult(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
  }
}
