import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/access_request_actions.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/alerts/app_alert_presentation.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

const _icon =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Alert _alert({
  String id = 'request-1',
  String title = 'App blocked',
  String body = 'Child requested access to com.example.security',
  String? requestType = 'access',
  String? appName = 'Metadata Security',
  String packageId = 'com.example.security',
  bool acknowledged = false,
  DateTime? createdAt,
  Map<String, dynamic> extraMetadata = const {},
}) =>
    Alert(
      id: id,
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'warning',
      category: 'app_blocked',
      title: title,
      body: body,
      metadata: {
        'packageId': packageId,
        if (appName != null) 'appName': appName,
        if (requestType != null) 'requestType': requestType,
        ...extraMetadata,
      },
      createdAt: createdAt ?? DateTime.utc(2026, 11, 25, 8),
      acknowledged: acknowledged,
    );

Map<String, dynamic> _alertJson(Alert alert) => {
      'id': alert.id,
      'childId': alert.childId,
      'deviceId': alert.deviceId,
      'severity': alert.severity,
      'category': alert.category,
      'title': alert.title,
      'body': alert.body,
      'metadata': alert.metadata,
      'createdAt': alert.createdAt!.toIso8601String(),
      'acknowledged': alert.acknowledged,
    };

Map<String, FakeRoute> _routes(
  List<Alert> alerts, {
  Map<String, dynamic>? family,
  List<Map<String, dynamic>>? installedApps,
}) {
  final routes = standardRoutes(
    familyMe: family,
    alerts: [for (final alert in alerts) _alertJson(alert)],
  );
  routes['GET /v1/devices/dev-1/apps'] = (_) => installedAppsPayload(
        apps: installedApps ??
            [
              installedAppJson('com.example.security', 'Security',
                  iconUrl: _icon)
            ],
      );
  for (final alert in alerts) {
    routes['POST /v1/alerts/${alert.id}/ack'] = (_) => {'ok': true};
  }
  return routes;
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<FakeApiClient> _pumpDetail(
  WidgetTester tester,
  Alert alert, {
  FakeApiClient? api,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  final client = api ?? FakeApiClient(_routes([alert]));
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: localizedTestApp(
        AlertDetailScreen(alertId: alert.id, initialAlert: alert),
        locale: locale,
        textDirection:
            locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      ),
    ),
  );
  await _flush(tester);
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Child Alerts tap opens general detail with request actions',
      (tester) async {
    final alert = _alert();
    final api = FakeApiClient(_routes([alert]));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
            const ChildDetailScreen(childId: 'child-1', initialTab: 4)),
      ),
    );
    await _flush(tester);

    await tester.tap(find.byType(AlertTile));
    await _flush(tester);

    expect(find.byType(AlertDetailScreen), findsOneWidget);
    expect(
        find.byKey(const ValueKey('alertDetailGeneralScroll')), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);
  });

  testWidgets(
      'top-level app_blocked opens full general detail instead of Close-only dialog',
      (tester) async {
    final alert = _alert();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(FakeApiClient(_routes([alert])))
        ],
        child: localizedTestApp(
            const AlertsScreen(liveRefreshInterval: Duration.zero)),
      ),
    );
    await _flush(tester);

    await tester.tap(find.byType(AlertTile));
    await _flush(tester);

    expect(find.byType(AlertDetailScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);
  });

  testWidgets(
      'current request metadata and exact legacy title both show actions',
      (tester) async {
    await _pumpDetail(tester, _alert());
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpDetail(
        tester, _alert(title: 'Access requested', requestType: null));
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);
  });

  testWidgets('ordinary blocks and lookalike titles never show request actions',
      (tester) async {
    for (final alert in [
      _alert(requestType: null),
      _alert(title: 'Access requested ', requestType: null),
      _alert(title: 'Access requested', requestType: 'other'),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpDetail(tester, alert);
      expect(find.text('Allow'), findsNothing, reason: alert.title);
      expect(find.text('Keep blocked'), findsNothing, reason: alert.title);
      expect(find.byIcon(Icons.block), findsOneWidget, reason: alert.title);
      expect(find.byIcon(Icons.pan_tool), findsNothing, reason: alert.title);
      expect(find.text(alert.body), findsNothing,
          reason: 'raw producer body must be suppressed');
    }
  });

  testWidgets(
      'unanswered current and legacy requests pin first; acknowledged requests use time order',
      (tester) async {
    final old = DateTime.utc(2026, 11, 20);
    final recent = DateTime.utc(2026, 11, 25);
    final ordinary =
        _alert(id: 'ordinary', requestType: null, createdAt: recent);
    final current = _alert(id: 'current', createdAt: old);
    final legacy = _alert(
        id: 'legacy',
        title: 'Access requested',
        requestType: null,
        createdAt: old);

    expect(mergeAlertsInPlace([ordinary], [current]).map((a) => a.id),
        ['current', 'ordinary']);
    expect(mergeAlertsInPlace([ordinary], [legacy]).map((a) => a.id),
        ['legacy', 'ordinary']);

    final acknowledged = _alert(id: 'done', createdAt: old, acknowledged: true);
    expect(mergeAlertsInPlace([ordinary], [acknowledged]).map((a) => a.id),
        ['ordinary', 'done']);
  });

  testWidgets('Allow PATCHes appRules before ACK and preserves unrelated rules',
      (tester) async {
    final alert = _alert();
    final routes = _routes([alert]);
    routes['GET /v1/rules/child-1'] = (_) => ruleSetPayload(
          'child-1',
          alwaysAllowedApps: ['com.example.phone'],
        );
    final api = FakeApiClient(routes);
    await _pumpDetail(tester, alert, api: api);

    await tester.tap(find.text('Allow'));
    await _flush(tester);

    final patches = api.calls('PATCH', '/v1/rules/child-1');
    final acknowledgements = api.calls('POST', '/v1/alerts/request-1/ack');
    expect(patches, hasLength(1));
    expect(acknowledgements, hasLength(1));
    final patchIndex = api.requests.indexOf(patches.single);
    final ackIndex = api.requests.indexOf(acknowledgements.single);
    expect(patchIndex, lessThan(ackIndex));

    expect(patches.single.body.keys, ['appRules']);
    expect(patches.single.body.containsKey('alwaysAllowedApps'), isFalse);
    final appRules =
        (patches.single.body['appRules'] as List).cast<Map<String, dynamic>>();
    expect(appRules, hasLength(2));
    expect(appRules[0], {
      'packageId': 'com.example.game',
      'appName': 'Game',
      'action': 'time_limit',
      'dailyLimitMinutes': 60,
    });
    expect(appRules[1], {
      'packageId': 'com.example.security',
      'appName': 'Security',
      'action': 'allow',
    });
    final resolved = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('access-request-resolved')),
        matching: find.byType(Text),
      ),
    );
    expect(resolved.data, contains('You allowed'));
    expect(resolved.data, contains('Security'));
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
  });

  testWidgets('Allow updates an existing app rule instead of duplicating it',
      (tester) async {
    final alert = _alert();
    final routes = _routes([alert]);
    routes['GET /v1/rules/child-1'] = (_) => {
          ...ruleSetPayload('child-1'),
          'appRules': [
            {
              'packageId': 'com.example.security',
              'appName': 'Old Security',
              'action': 'block',
            },
          ],
        };
    final api = FakeApiClient(routes);
    await _pumpDetail(tester, alert, api: api);

    await tester.tap(find.text('Allow'));
    await _flush(tester);

    final appRules = (api
            .calls('PATCH', '/v1/rules/child-1')
            .single
            .body['appRules'] as List)
        .cast<Map>();
    expect(appRules, hasLength(1));
    expect(appRules.single['packageId'], 'com.example.security');
    expect(appRules.single['action'], 'allow');
  });

  testWidgets('failed Allow keeps actions, shows inline error, and never ACKs',
      (tester) async {
    final alert = _alert();
    final routes = _routes([alert]);
    routes['PATCH /v1/rules/child-1'] = (_) => const FakeHttpError(500);
    final api = FakeApiClient(routes);
    await _pumpDetail(tester, alert, api: api);

    await tester.tap(find.text('Allow'));
    await _flush(tester);

    expect(api.calls('POST', '/v1/alerts/request-1/ack'), isEmpty);
    expect(
        find.text(
            "Couldn't allow \u{2068}Security\u{2069}. Check your connection and try again."),
        findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);
  });

  testWidgets('Keep blocked ACKs without any rules mutation', (tester) async {
    final alert = _alert();
    final api = FakeApiClient(_routes([alert]));
    await _pumpDetail(tester, alert, api: api);

    await tester.tap(find.text('Keep blocked'));
    await _flush(tester);

    expect(api.calls('POST', '/v1/alerts/request-1/ack'), hasLength(1));
    expect(api.calls('PATCH', '/v1/rules/child-1'), isEmpty);
    expect(api.calls('PUT', '/v1/rules/child-1'), isEmpty);
    expect(api.calls('GET', '/v1/rules/child-1'), isEmpty);
    final resolved = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('access-request-resolved')),
        matching: find.byType(Text),
      ),
    );
    expect(resolved.data, contains('You kept'));
    expect(resolved.data, contains('Security'));
    expect(resolved.data, contains('blocked'));
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
  });

  testWidgets(
      'failed Keep blocked ACK keeps actions and shows ACK error without rules mutation',
      (tester) async {
    final alert = _alert();
    final routes = _routes([alert]);
    routes['POST /v1/alerts/request-1/ack'] = (_) => const FakeHttpError(500);
    final api = FakeApiClient(routes);
    await _pumpDetail(tester, alert, api: api);

    await tester.tap(find.text('Keep blocked'));
    await _flush(tester);

    expect(api.calls('PATCH', '/v1/rules/child-1'), isEmpty);
    expect(api.calls('PUT', '/v1/rules/child-1'), isEmpty);
    expect(
        find.text(
            "Couldn't dismiss alert. Check your connection and try again."),
        findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);
    expect(find.textContaining('You kept'), findsNothing);
  });

  testWidgets('saving disables both buttons and shows Allowing with a spinner',
      (tester) async {
    final alert = _alert();
    final completer = Completer<Object?>();
    final routes = _routes([alert]);
    routes['PATCH /v1/rules/child-1'] = (_) => FakeDeferred(completer.future);
    await _pumpDetail(tester, alert, api: FakeApiClient(routes));

    await tester.tap(find.text('Allow'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Allowing…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Allowing…'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Keep blocked'))
            .onPressed,
        isNull);

    completer.complete({'ok': true});
    await _flush(tester);
  });

  testWidgets(
      'installed label and icon outrank metadata and raw body is suppressed',
      (tester) async {
    await _pumpDetail(tester, _alert());

    final title = tester
        .widget<Text>(find.byKey(const ValueKey('alertDetailTitle')))
        .data!;
    expect(title, contains('Security'));
    expect(title, isNot(contains('Metadata Security')));
    expect(title, isNot(contains('com.example.security')));
    expect(find.text('Child requested access to com.example.security'),
        findsNothing);
    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images.any((image) => image.image is MemoryImage), isTrue);
  });

  testWidgets(
      'metadata appName is the fallback when installed inventory has no match',
      (tester) async {
    final alert = _alert();
    final api = FakeApiClient(_routes([
      alert
    ], installedApps: [
      installedAppJson('com.example.other', 'Other'),
    ]));
    await _pumpDetail(tester, alert, api: api);

    final title = tester
        .widget<Text>(find.byKey(const ValueKey('alertDetailTitle')))
        .data!;
    expect(title, contains('Metadata Security'));
    expect(title, isNot(contains('com.example.security')));
  });

  testWidgets(
      'package fallback uses LTR isolate while child and known names use FSI',
      (tester) async {
    final alert = _alert(appName: null);
    await _pumpDetail(
      tester,
      alert,
      api: FakeApiClient(_routes([alert], installedApps: const [])),
    );

    final title = tester
        .widget<Text>(find.byKey(const ValueKey('alertDetailTitle')))
        .data!;
    final body = tester
        .widget<Text>(find.byKey(const ValueKey('alertDetailBody')))
        .data!;
    expect(title, contains('\u{2066}com.example.security\u{2069}'));
    expect(title, isNot(contains('\u{2068}com.example.security\u{2069}')));
    expect(body, contains('\u{2068}Alex\u{2069}'));
    expect(body, isNot(contains('com.example.security')));
  });

  testWidgets(
      'Arabic uses exact request copy and isolates child and app with FSI',
      (tester) async {
    await _pumpDetail(tester, _alert(), locale: const Locale('ar'));

    expect(find.text('طلب السماح باستخدام تطبيق'), findsOneWidget);
    final body = tester
        .widget<Text>(find.byKey(const ValueKey('alertDetailBody')))
        .data!;
    expect(body,
        'وصل طلب من \u{2068}Alex\u{2069} للسماح باستخدام \u{2068}Security\u{2069}.');
    expect(find.text('السماح'), findsOneWidget);
    expect(find.text('رفض'), findsOneWidget);
    expect(
      find.text(
          'سيُسمح بتطبيق \u{2068}Security\u{2069} من الآن، مع استمرار تطبيق وقت النوم والساعات المدرسية والإيقاف المؤقت.'),
      findsOneWidget,
    );
    expect(find.text('Child requested access to com.example.security'),
        findsNothing);
  });

  testWidgets(
      'guardian without rules permission is read-only with owner guidance',
      (tester) async {
    final family = familyMeTwoChildren();
    family['parent'] = {
      ...(family['parent'] as Map<String, dynamic>),
      'role': 'guardian',
      'permissions': ['alerts'],
    };
    family['parents'] = [
      family['parent'],
      {
        'id': 'owner-1',
        'familyId': 'fam-1',
        'email': 'owner@example.com',
        'displayName': 'Mariam',
        'role': 'owner',
        'permissions': <String>[],
      },
    ];
    await _pumpDetail(tester, _alert(),
        api: FakeApiClient(_routes([_alert()], family: family)));

    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(
        find.text(
            'Only \u{2068}Mariam\u{2069} can answer this request. Ask them to open OSRA.'),
        findsOneWidget);
  });

  testWidgets(
      'legacy ACK shows resolved handled state without inventing an outcome',
      (tester) async {
    await _pumpDetail(tester, _alert(acknowledged: true));

    expect(find.text('This request was handled'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
    expect(find.textContaining('You allowed'), findsNothing);
    expect(find.textContaining('You kept'), findsNothing);
  });

  testWidgets(
      'co-parent resolution uses named allowed outcome and time when metadata provides it',
      (tester) async {
    await _pumpDetail(
      tester,
      _alert(
        acknowledged: true,
        extraMetadata: {
          'resolution': 'allowed',
          'resolvedByName': 'Mariam',
          'resolvedAt': '2026-11-25T08:05:00.000Z',
        },
      ),
    );

    final resolved = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('access-request-resolved')),
        matching: find.byType(Text),
      ),
    );
    expect(resolved.data, contains('Mariam'));
    expect(resolved.data, contains('allowed'));
    expect(resolved.data, contains('Security'));
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
  });

  testWidgets('request actions stay hidden until parent permissions load',
      (tester) async {
    final alert = _alert();
    final family = Completer<Object?>();
    final routes = _routes([alert]);
    routes['GET /v1/family/me'] = (_) => FakeDeferred(family.future);
    await _pumpDetail(tester, alert, api: FakeApiClient(routes));

    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);

    family.complete(familyMeTwoChildren());
    await _flush(tester);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Keep blocked'), findsOneWidget);
  });

  testWidgets('a live co-parent resolution replaces the unanswered actions',
      (tester) async {
    final alert = _alert();
    final api = FakeApiClient(_routes([alert]));
    final currentAlert = ValueNotifier<Alert>(alert);
    addTearDown(currentAlert.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          Scaffold(
            body: ValueListenableBuilder<Alert>(
              valueListenable: currentAlert,
              builder: (_, current, __) => AccessRequestActions(
                alert: current,
                identity: resolveAppAlertIdentity(
                  current,
                  const InstalledAppsReport(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    expect(find.text('Allow'), findsOneWidget);

    currentAlert.value = _alert(
      acknowledged: true,
      extraMetadata: {
        'resolution': 'kept_blocked',
        'resolvedByName': 'Mariam',
        'resolvedAt': '2026-11-25T08:05:00.000Z',
      },
    );
    await _flush(tester);

    final resolved = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('access-request-resolved')),
        matching: find.byType(Text),
      ),
    );
    expect(resolved.data, contains('Mariam'));
    expect(resolved.data, contains('kept'));
    expect(resolved.data, contains('blocked'));
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
  });

  testWidgets(
      'co-parent capabilities match the rules and alerts API permissions',
      (tester) async {
    final alert = _alert();
    final family = familyMeTwoChildren();
    family['parent'] = {
      ...(family['parent'] as Map<String, dynamic>),
      'role': 'co-parent',
      'permissions': ['alerts'],
    };
    await _pumpDetail(
      tester,
      alert,
      api: FakeApiClient(_routes([alert], family: family)),
    );
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsOneWidget);

    family['parent'] = {
      ...(family['parent'] as Map<String, dynamic>),
      'permissions': ['rules'],
    };
    final api = FakeApiClient(_routes([alert], family: family));
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpDetail(tester, alert, api: api);
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
    expect(api.calls('PATCH', '/v1/rules/child-1'), isEmpty);
    expect(api.calls('POST', '/v1/alerts/request-1/ack'), isEmpty);
  });

  testWidgets('opened detail follows a refreshed alert instead of its snapshot',
      (tester) async {
    var current = _alert();
    final routes = _routes([current]);
    routes['GET /v1/alerts'] = (req) => req.query['ack'] == 'false'
        ? {
            'items': <dynamic>[],
            'meta': {'total': 0, 'page': 1, 'limit': 1},
          }
        : {
            'items': [_alertJson(current)],
            'total': 1,
            'page': 1,
            'limit': 20,
          };
    final api = FakeApiClient(routes);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedTestApp(
          AlertDetailScreen(alertId: current.id, initialAlert: current),
        ),
      ),
    );
    await _flush(tester);
    expect(find.text('Allow'), findsOneWidget);

    current = _alert(
      acknowledged: true,
      extraMetadata: {
        'resolution': 'allowed',
        'resolvedByName': 'Mariam',
        'resolvedAt': '2026-11-25T08:05:00.000Z',
      },
    );
    container.invalidate(alertsProvider(const AlertFilter()));
    await _flush(tester);

    expect(find.text('Allow'), findsNothing);
    expect(find.text('Keep blocked'), findsNothing);
    expect(find.textContaining('Mariam'), findsOneWidget);
  });

  testWidgets(
      'ACK refresh preserves the local decision without server metadata',
      (tester) async {
    var current = _alert();
    final routes = _routes([current]);
    routes['GET /v1/alerts'] = (req) => req.query['ack'] == 'false'
        ? {
            'items': <dynamic>[],
            'meta': {'total': 0, 'page': 1, 'limit': 1},
          }
        : {
            'items': [_alertJson(current)],
            'total': 1,
            'page': 1,
            'limit': 20,
          };
    routes['POST /v1/alerts/request-1/ack'] = (_) {
      current = _alert(acknowledged: true);
      return {'ok': true};
    };
    final api = FakeApiClient(routes);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedTestApp(
          AlertDetailScreen(alertId: current.id, initialAlert: current),
        ),
      ),
    );
    await _flush(tester);

    await tester.tap(find.text('Keep blocked'));
    await _flush(tester);

    final resolved = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('access-request-resolved')),
        matching: find.byType(Text),
      ),
    );
    expect(resolved.data, contains('You kept'));
    expect(resolved.data, contains('Security'));
    expect(resolved.data, contains('blocked'));
    expect(resolved.data, isNot('This request was handled'));
  });

  testWidgets('rendered feed keeps old unanswered requests above newer days',
      (tester) async {
    final request = _alert(createdAt: DateTime.utc(2026, 11, 24, 8));
    final ordinary = _alert(
      id: 'ordinary',
      requestType: null,
      createdAt: DateTime.utc(2026, 11, 25, 8),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(
            FakeApiClient(_routes([ordinary, request])),
          ),
        ],
        child: localizedTestApp(
          const AlertsScreen(liveRefreshInterval: Duration.zero),
        ),
      ),
    );
    await _flush(tester);

    final tiles = tester.widgetList<AlertTile>(find.byType(AlertTile)).toList();
    expect(tiles, hasLength(2));
    expect(tiles.first.alert.id, request.id);
  });

  testWidgets('installed identity comes from the alert device when known',
      (tester) async {
    final alert = Alert(
      id: 'request-1',
      childId: 'child-1',
      deviceId: 'dev-2',
      severity: 'warning',
      category: 'app_blocked',
      title: 'App blocked',
      body: 'Child requested access to com.example.security',
      metadata: const {
        'packageId': 'com.example.security',
        'appName': 'Metadata Security',
        'requestType': 'access',
      },
      createdAt: DateTime.utc(2026, 11, 25, 8),
      acknowledged: false,
    );
    final family = familyMeTwoChildren();
    final devices = (family['devices'] as List).cast<Map<String, dynamic>>();
    devices[1]['childId'] = 'child-1';
    final routes = _routes([alert], family: family);
    routes['GET /v1/devices/dev-1/apps'] = (_) => installedAppsPayload(
          apps: [installedAppJson('com.example.security', 'First Security')],
        );
    routes['GET /v1/devices/dev-2/apps'] = (_) => installedAppsPayload(
          apps: [installedAppJson('com.example.security', 'Second Security')],
        );
    await _pumpDetail(tester, alert, api: FakeApiClient(routes));

    final title = tester
        .widget<Text>(find.byKey(const ValueKey('alertDetailTitle')))
        .data!;
    expect(title, contains('Second Security'));
    expect(title, isNot(contains('First Security')));
  });
}
