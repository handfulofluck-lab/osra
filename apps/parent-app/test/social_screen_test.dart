import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets the fake-Dio zero-duration timer chains complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder fieldByLabel(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));

  /// The vertical Scrollable of the shared social sections list.
  Finder socialScrollable() => find.descendant(
        of: find.byKey(const ValueKey('socialSectionsList')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      );

  /// Scrolls the lazy sections list until [finder]'s widget is built and visible.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 150, scrollable: socialScrollable());
    await tester.pumpAndSettle();
  }

  /// Route table extending [standardRoutes] with social/activity feeds and a
  /// rules payload carrying the Feature #2 fields.
  Map<String, FakeRoute> socialRoutes({
    List<Map<String, dynamic>> concerns = const [],
    List<Map<String, dynamic>> calls = const [],
    List<Map<String, dynamic>> sms = const [],
    Map<String, bool>? socialMonitoring,
    List<String>? contactAllowlist,
  }) =>
      {
        ...standardRoutes(),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', socialMonitoring: socialMonitoring, contactAllowlist: contactAllowlist),
        'GET /v1/social/events': (req) => req.query['childId'] == 'child-1'
            ? {'items': concerns, 'meta': {'total': concerns.length}}
            : {'items': <dynamic>[], 'meta': {'total': 0}},
        'GET /v1/reports/activity': (req) => req.query['type'] == 'call'
            ? {'items': calls, 'meta': {'total': calls.length}}
            : {'items': sms, 'meta': {'total': sms.length}},
      };

  Map<String, dynamic> concernJson({
    String id = 'se-1',
    String app = 'whatsapp',
    String contact = 'Maya',
    String severity = 'warning',
    List<String> concernTypes = const ['grooming_risk', 'late_night'],
    DateTime? at,
  }) =>
      {
        'id': id,
        'app': app,
        'contact': contact,
        'severity': severity,
        'preview': 'Are you coming tonight? Don\'t tell your parents.',
        'concernTypes': concernTypes,
        'createdAt': (at ?? DateTime.now().subtract(const Duration(hours: 2))).toUtc().toIso8601String(),
      };

  Map<String, dynamic> callJson({
    String id = 'act-call',
    String number = '+15551234567',
    int durationSec = 95,
    String direction = 'outgoing',
    DateTime? at,
  }) =>
      {
        'id': id,
        'type': 'call',
        'payload': {'number': number, 'durationSec': durationSec, 'direction': direction},
        'ts': (at ?? DateTime.now().subtract(const Duration(minutes: 30))).toUtc().toIso8601String(),
      };

  Map<String, dynamic> smsJson({
    String id = 'act-sms',
    String number = '+15557654321',
    String bodyPreview = 'running late, see you at 5',
    DateTime? at,
  }) =>
      {
        'id': id,
        'type': 'sms',
        'payload': {'number': number, 'bodyPreview': bodyPreview},
        'ts': (at ?? DateTime.now().subtract(const Duration(minutes: 10))).toUtc().toIso8601String(),
      };

  group('Monitoring toggles', () {
    testWidgets('render from rules payload; apps absent from the map default to ON', (tester) async {
      final api = FakeApiClient(socialRoutes(socialMonitoring: {'whatsapp': false, 'tiktok': false}));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'WhatsApp')).value, isFalse);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'TikTok')).value, isFalse);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Instagram')).value, isTrue);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Discord')).value, isTrue);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'LINE')).value, isTrue);
    });

    testWidgets('all eight apps default to ON when the payload has no socialMonitoring', (tester) async {
      final api = FakeApiClient(socialRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      for (final a in kSocialApps) {
        expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, a.label)).value, isTrue, reason: '${a.label} should default ON');
      }
    });

    testWidgets('flip + save PUTs the merged socialMonitoring map', (tester) async {
      final api = FakeApiClient(socialRoutes(socialMonitoring: {'whatsapp': true}));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await tester.tap(find.widgetWithText(SwitchListTile, 'WhatsApp'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save monitoring'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      final social = Map<String, dynamic>.from(puts.single.body['socialMonitoring'] as Map);
      expect(social['whatsapp'], isFalse);
      expect(social.keys, hasLength(8));
      expect(puts.single.body.keys, containsAll(['screenTime', 'webFilter', 'appRules', 'routines', 'socialMonitoring']));
      expect(find.text('Monitoring saved'), findsOneWidget);
    });
  });

  group('Concerns vault', () {
    testWidgets('renders severity-colored cards with concern chips and an expandable preview', (tester) async {
      final api = FakeApiClient(socialRoutes(concerns: [concernJson()]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('Maya'));
      expect(find.text('Maya'), findsOneWidget);
      expect(find.text('grooming_risk'), findsOneWidget);
      expect(find.text('late_night'), findsOneWidget);
      expect(find.textContaining('WhatsApp · '), findsOneWidget);
      // Severity tint on the card + colored leading icon.
      final card = find.ancestor(of: find.text('Maya'), matching: find.byType(Card));
      expect(tester.widget<Card>(card).color, isNotNull);

      const preview = 'Are you coming tonight? Don\'t tell your parents.';
      expect(find.text(preview), findsNothing);
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      expect(find.text(preview), findsOneWidget);
    });

    testWidgets('shows the empty state when there are no concerns', (tester) async {
      final api = FakeApiClient(socialRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      expect(find.text('No concerns detected'), findsOneWidget);
    });
  });

  group('Contact allowlist', () {
    testWidgets('add normalizes digits and save PUTs contactAllowlist', (tester) async {
      final api = FakeApiClient(socialRoutes(contactAllowlist: const []));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final phoneField = fieldByLabel('Phone number');
      await reveal(tester, phoneField);
      await tester.enterText(phoneField, '+1 (555) 123-4567');
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(find.text('15551234567'), findsOneWidget);

      await reveal(tester, find.text('Save allowlist'));
      await tester.tap(find.text('Save allowlist'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      expect(puts.single.body['contactAllowlist'], ['15551234567']);
    });

    testWidgets('removing a chip and saving PUTs the updated contactAllowlist', (tester) async {
      final api = FakeApiClient(socialRoutes(contactAllowlist: ['15550001122', '15553334445']));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('15550001122'));
      tester.widget<InputChip>(find.widgetWithText(InputChip, '15550001122')).onDeleted!();
      await tester.pumpAndSettle();
      expect(find.text('15550001122'), findsNothing);

      await reveal(tester, find.text('Save allowlist'));
      await tester.tap(find.text('Save allowlist'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('PUT', '/v1/rules/child-1').single.body['contactAllowlist'], ['15553334445']);
    });
  });

  group('Calls & texts timeline (#6)', () {
    testWidgets('renders call rows (direction icon, mm:ss) and sms rows (120-char preview), day-grouped', (tester) async {
      final now = DateTime.now();
      final api = FakeApiClient(socialRoutes(
        calls: [
          callJson(direction: 'outgoing', durationSec: 95, at: now.subtract(const Duration(minutes: 40))),
          callJson(id: 'act-call-2', number: '+15550002222', direction: 'incoming', durationSec: 12, at: now.subtract(const Duration(hours: 26))),
        ],
        sms: [smsJson(bodyPreview: 'x' * 200, at: now.subtract(const Duration(minutes: 10)))],
      ));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.byIcon(Icons.call_made));
      expect(find.byIcon(Icons.call_made), findsOneWidget);
      expect(find.byIcon(Icons.call_received), findsOneWidget);
      expect(find.byIcon(Icons.sms_outlined), findsOneWidget);
      expect(find.text('+15551234567'), findsOneWidget);
      expect(find.text('01:35'), findsOneWidget);
      expect(find.text('00:12'), findsOneWidget);
      // 200-char body is capped at 120 chars.
      expect(find.text('${'x' * 120}…'), findsOneWidget);
      // Day groups: today and yesterday headers.
      expect(find.text(DateFormat('EEEE, MMM d, yyyy').format(now)), findsOneWidget);
      await reveal(tester, find.text(DateFormat('EEEE, MMM d, yyyy').format(now.subtract(const Duration(days: 1)))));
      expect(find.text(DateFormat('EEEE, MMM d, yyyy').format(now.subtract(const Duration(days: 1)))), findsOneWidget);
    });

    testWidgets('shows the empty state and the iOS NOTE', (tester) async {
      final api = FakeApiClient(socialRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('No calls or texts yet'));
      expect(find.text('No calls or texts yet'), findsOneWidget);
      expect(find.text('iOS does not support call/text monitoring.'), findsOneWidget);
    });

    testWidgets('fetches type=call and type=sms and merges newest-first', (tester) async {
      final now = DateTime.now();
      final api = FakeApiClient(socialRoutes(
        calls: [callJson(at: now.subtract(const Duration(minutes: 5)))],
        sms: [smsJson(at: now.subtract(const Duration(minutes: 1)))],
      ));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final gets = api.calls('GET', '/v1/reports/activity');
      expect(gets, hasLength(2));
      expect(gets.map((r) => r.query['type']), containsAll(['call', 'sms']));
      // Newest (sms, 1 min ago) renders above the older call.
      await reveal(tester, find.text('running late, see you at 5'));
      final smsTop = tester.getTopLeft(find.byIcon(Icons.sms_outlined));
      final callTop = tester.getTopLeft(find.byIcon(Icons.call_made));
      expect(smsTop.dy, lessThan(callTop.dy));
    });
  });

  group('Child detail Social tab', () {
    testWidgets('embeds the social sections and the Overview entry jumps to the tab', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      // Overview entry ListTile with chevron.
      expect(find.text('Social monitoring'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.text('Social'));
      await tester.pumpAndSettle();
      await flushFakeHttp(tester);

      expect(find.text('Monitoring'), findsOneWidget);
      await reveal(tester, find.text('Concerns'));
      expect(find.text('Concerns'), findsOneWidget);
      await reveal(tester, find.text('Calls & texts'));
      expect(find.text('Calls & texts'), findsOneWidget);
      await reveal(tester, find.text('Trusted contacts'));
      expect(find.text('Trusted contacts'), findsOneWidget);
      await reveal(tester, find.text('No concerns detected'));
      expect(find.text('No concerns detected'), findsOneWidget);
      await reveal(tester, find.text('No calls or texts yet'));
      expect(find.text('No calls or texts yet'), findsOneWidget);
    });
  });
}
