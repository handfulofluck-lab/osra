import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/rules/rules_behind_banner.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';

/// #1128 regression & fail-first tests:
/// 1. Blocked-site (`web_threat`) alert with `metadata['domain']` shows the domain (LTR-isolated).
///    Mutant: omitting `metadata['domain']` lookup in `formatGeneralAlertBody` fails the domain assertion.
/// 2. Blocked-site alert without `metadata['domain']` shows the localized "not collected yet" line.
///    Mutant: returning only `alert.body` when `domain` is absent fails the notice assertion.
/// 3. No `RulesBehindBanner` appears on any alert detail (general detail, social detail, or feed dialog),
///    even when the child's device has `appliedRulesVersion < rulesVersion`.
///    Mutant: leaving `RulesBehindBanner(childId: ...)` in `AlertDetailScreen` or `AlertsScreen` fails the
///    `findsNothing` assertions below.

FakeApiClient _behindApi({List<Map<String, dynamic>>? alerts}) {
  final base = standardRoutes();
  return FakeApiClient({
    ...base,
    'GET /v1/family/overview': (_) => {
          'family': {'id': 'fam-1', 'name': 'Test Family'},
          'children': [
            {
              'id': 'child-1',
              'displayName': 'Lina',
              'birthYear': 2015,
              'rulesVersion': 5,
            },
          ],
          'devices': [
            {
              'id': 'dev-1',
              'childId': 'child-1',
              'platform': 'android',
              'model': 'Redmi Note',
              'status': 'online',
              'appliedRulesVersion': 3,
            },
          ],
          'unacknowledgedAlerts': 1,
        },
    if (alerts != null)
      'GET /v1/alerts': (_) => {
            'items': alerts,
            'total': alerts.length,
            'page': 1,
            'limit': 50,
          },
  });
}

Alert _webThreatAlert({
  String id = 'alert-web-1',
  Map<String, dynamic> metadata = const {},
}) =>
    Alert(
      id: id,
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'warning',
      category: 'web_threat',
      title: 'Blocked site opened',
      body: 'Your child tried to open a blocked site.',
      metadata: metadata,
      createdAt: DateTime.utc(2026, 11, 25, 12, 2),
    );

Alert _socialAlert() => Alert(
      id: 'alert-social-1',
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'critical',
      category: 'social_concern',
      title: 'Social concern in WhatsApp',
      body: 'Flagged message',
      metadata: const {
        'app': 'whatsapp',
        'contact': 'Sam',
        'concernTypes': ['grooming_risk'],
        'flaggedCount': 1,
        'latestAt': '2026-11-25T12:02:00.000Z',
      },
      createdAt: DateTime.utc(2026, 11, 25, 12, 2),
    );

Widget _wrap(
  Widget child, {
  required FakeApiClient api,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api)],
    child: MaterialApp(
      locale: locale,
      theme: AppTheme.light,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: inner!,
      ),
      home: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await configureDateFormatting();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  for (final locale in const [Locale('en'), Locale('ar')]) {
    final isAr = locale.languageCode == 'ar';

    testWidgets(
      '#1128 (${locale.languageCode}): web_threat with metadata.domain shows LTR-isolated domain and no RulesBehindBanner',
      (tester) async {
        final alert = _webThreatAlert(metadata: const {'domain': 'example.org'});

        await tester.pumpWidget(_wrap(
          AlertDetailScreen(alertId: alert.id, initialAlert: alert),
          api: _behindApi(),
          locale: locale,
          textScale: 2.0,
        ));
        await tester.pumpAndSettle();

        expect(find.byType(RulesBehindBanner), findsNothing);
        expect(find.textContaining('\u2066example.org\u2069'), findsOneWidget);
        expect(
          find.textContaining(isAr ? 'الموقع:' : 'Site:'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '#1128 (${locale.languageCode}): web_threat without metadata.domain shows not-collected notice and no RulesBehindBanner',
      (tester) async {
        final alert = _webThreatAlert(metadata: const {});

        await tester.pumpWidget(_wrap(
          AlertDetailScreen(alertId: alert.id, initialAlert: alert),
          api: _behindApi(),
          locale: locale,
          textScale: 2.0,
        ));
        await tester.pumpAndSettle();

        expect(find.byType(RulesBehindBanner), findsNothing);
        expect(
          find.textContaining(
            isAr
                ? 'لا تُجمع أسماء المواقع حاليًا'
                : "Site names aren't collected yet",
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    '#1128: social alert detail never renders RulesBehindBanner even when device rules are behind',
    (tester) async {
      final alert = _socialAlert();
      await tester.pumpWidget(_wrap(
        AlertDetailScreen(alertId: alert.id, initialAlert: alert),
        api: _behindApi(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(RulesBehindBanner), findsNothing);
    },
  );

  testWidgets(
    '#1128: AlertsScreen feed dialog for web_threat shows domain and never renders RulesBehindBanner',
    (tester) async {
      final api = _behindApi(alerts: [
        {
          'id': 'alert-web-2',
          'childId': 'child-1',
          'deviceId': 'dev-1',
          'severity': 'warning',
          'category': 'web_threat',
          'title': 'Blocked site opened',
          'body': 'Your child tried to open a blocked site.',
          'metadata': {'domain': 'blocked.test'},
          'createdAt': '2026-11-25T12:02:00.000Z',
        },
      ]);
      await tester.pumpWidget(_wrap(
        const AlertsScreen(),
        api: api,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Blocked site attempted'));
      await tester.pumpAndSettle();

      expect(find.byType(RulesBehindBanner), findsNothing);
      expect(find.textContaining('\u2066blocked.test\u2069'), findsOneWidget);
    },
  );
}
