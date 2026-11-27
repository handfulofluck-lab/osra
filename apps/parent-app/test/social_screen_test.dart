import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';
import 'frame_capture.dart';
import 'social_app_fixtures.dart';
import 'test_app.dart';

/// Fixed local wall-clock base for every seeded timestamp in this file.
///
/// Never derive a fixture from `DateTime.now()`: a "40 minutes ago" event
/// crosses midnight when the suite runs at 00:00-00:40 local, and "26 hours
/// ago" is two days back at 00:00-02:00, so the asserted day headers vanish
/// (issue #176 — a two-hour red window every day).
final DateTime testNow = DateTime(2026, 10, 19, 12, 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFrameFonts);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api,
      {bool tall = false,
      Locale locale = const Locale('en'),
      bool frameBoundary = false,
      bool dark = false,
      bool uxP17 = true}) async {
    if (tall) {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        // P-17 (#1179) ships behind `OSRA_UX_P17`; these rows test the new shape.
        p17SocialEnabledProvider.overrideWithValue(uxP17),
      ],
      child: localizedTestApp(
        frameBoundary
            ? RepaintBoundary(key: const ValueKey('frameRoot'), child: home)
            : home,
        locale: locale,
        theme: withFrameFonts(dark ? AppTheme.dark : AppTheme.light),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets the fake-Dio zero-duration timer chains complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder fieldByLabel(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextField));

  /// P-17: the row states the app's state in words, and `Off` is the only one that means the parent turned it
  /// off. There is no switch to read any more.
  bool socialAppOn(WidgetTester tester, String appKey) =>
      tester.widget<Text>(find.byKey(ValueKey('socialAppState-$appKey'))).data != 'Off';

  Finder socialAppRow(String appKey) => find.byKey(ValueKey('socialAppRow-$appKey'));

  /// Taps the row and chooses on/off in the sheet the row opens.
  Future<void> chooseSocialApp(WidgetTester tester, String appKey, {required bool on}) async {
    await tester.tap(socialAppRow(appKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('${on ? 'socialAppOn' : 'socialAppOff'}-$appKey')));
    await tester.pumpAndSettle();
  }

  /// The vertical Scrollable of the shared social sections list.
  Finder socialScrollable() => find.descendant(
        of: find.byKey(const ValueKey('socialSectionsList')),
        matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axis == Axis.vertical),
      );

  /// Scrolls the lazy sections list until [finder]'s widget is built and visible.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 150,
        scrollable: socialScrollable());
    await tester.pumpAndSettle();
  }

  /// Route table extending [standardRoutes] with social/activity feeds and a
  /// rules payload carrying the Feature #2 fields.
  Map<String, FakeRoute> socialRoutes({
    List<Map<String, dynamic>> concerns = const [],
    List<Map<String, dynamic>> calls = const [],
    List<Map<String, dynamic>> sms = const [],
    List<Map<String, dynamic>> locks = const [],
    Map<String, bool>? socialMonitoring,
    List<String>? contactAllowlist,
    List<Map<String, dynamic>>? installedApps,
    Map<String, dynamic>? familyMe,
  }) =>
      {
        ...standardRoutes(familyMe: familyMe),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1',
            socialMonitoring: socialMonitoring,
            contactAllowlist: contactAllowlist),
        'GET /v1/devices/dev-1/apps': (_) =>
            installedAppsPayload(apps: installedApps ?? socialInventory()),
        'GET /v1/social/events': (req) => req.query['childId'] == 'child-1'
            ? {
                'items': concerns,
                'meta': {'total': concerns.length}
              }
            : {
                'items': <dynamic>[],
                'meta': {'total': 0}
              },
        'GET /v1/reports/activity': (req) => switch (req.query['type']) {
              'call' => {
                  'items': calls,
                  'meta': {'total': calls.length}
                },
              'sms' => {
                  'items': sms,
                  'meta': {'total': sms.length}
                },
              'lock_period' => {
                  'items': locks,
                  'meta': {'total': locks.length}
                },
              _ => {
                  'items': <dynamic>[],
                  'meta': {'total': 0}
                },
            },
      };

  Map<String, dynamic> concernJson({
    String id = 'se-1',
    String app = 'whatsapp',
    String contact = 'Maya',
    String severity = 'warning',
    List<String> concernTypes = const ['grooming_risk', 'late_night'],
    DateTime? at,
    Object? latestFeedback,
    Object? ownFeedback,
  }) =>
      {
        'id': id,
        'app': app,
        'contact': contact,
        'severity': severity,
        'preview': 'Are you coming tonight? Don\'t tell your parents.',
        'concernTypes': concernTypes,
        'createdAt': (at ?? testNow.subtract(const Duration(hours: 2)))
            .toUtc()
            .toIso8601String(),
        if (latestFeedback != null) 'latestFeedback': latestFeedback,
        'ownFeedback': ownFeedback,
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
        'payload': {
          'number': number,
          'durationSec': durationSec,
          'direction': direction
        },
        'ts': (at ?? testNow.subtract(const Duration(minutes: 30)))
            .toUtc()
            .toIso8601String(),
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
        'ts': (at ?? testNow.subtract(const Duration(minutes: 10)))
            .toUtc()
            .toIso8601String(),
      };

  group('Monitoring toggles', () {
    testWidgets(
        'the shared catalog covers all 12 monitored apps and keys X as twitter',
        (tester) async {
      expect(
        kSocialApps.map((a) => a.appKey).toList(),
        [
          'whatsapp',
          'instagram',
          'tiktok',
          'snapchat',
          'twitter',
          'discord',
          'roblox',
          'line',
          'youtube',
          'telegram',
          'reddit',
          'messenger'
        ],
      );
      expect(socialAppIcon('twitter'), Icons.alternate_email);
      expect(socialAppIcon('x'), Icons.alternate_email);
    });

    testWidgets(
        'render from rules payload; apps absent from the map default to ON',
        (tester) async {
      final api = FakeApiClient(
          socialRoutes(socialMonitoring: {'whatsapp': false, 'tiktok': false}));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      expect(
          socialAppOn(tester, 'whatsapp'),
          isFalse);
      expect(
          socialAppOn(tester, 'tiktok'),
          isFalse);
      expect(
          socialAppOn(tester, 'instagram'),
          isTrue);
      expect(
          socialAppOn(tester, 'discord'),
          isTrue);
      expect(
          socialAppOn(tester, 'line'),
          isTrue);
    });

    testWidgets(
        'canonical twitter wins over legacy x and legacy x survives when canonical is absent',
        (tester) async {
      final cases = <({Map<String, bool> monitoring, bool expected})>[
        (monitoring: {'twitter': false, 'x': true}, expected: false),
        (monitoring: {'twitter': true, 'x': false}, expected: true),
        (monitoring: {'x': false}, expected: false),
      ];
      for (final entry in cases) {
        final api =
            FakeApiClient(socialRoutes(socialMonitoring: entry.monitoring));
        await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
            tall: true);
        await flushFakeHttp(tester);
        expect(
          socialAppOn(tester, 'twitter'),
          entry.expected,
          reason: 'rule map ${entry.monitoring} must control X',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets(
        'all apps default to ON when the payload has no socialMonitoring',
        (tester) async {
      final api = FakeApiClient(socialRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      for (final a in kSocialApps) {
        expect(
            socialAppOn(tester, a.appKey),
            isTrue,
            reason: '${a.label} should default ON');
      }
    });

    testWidgets(
        'installed apps sort first and the collapsed group keeps its switches usable',
        (tester) async {
      final api = FakeApiClient(socialRoutes(
        socialMonitoring: {'whatsapp': false},
        installedApps: socialInventory({'telegram', 'whatsapp', 'youtube'}),
      ));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      expect(find.text('Check messages in'), findsOneWidget);
      expect(
          find.text(
              'OSRA only flags concerning messages. It never shows you every chat.'),
          findsOneWidget);
      expect(find.text('Not on Alex\'s phone (9)'), findsOneWidget);
      expect(socialAppRow('instagram'), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('socialAppState-whatsapp'))).data, 'Off');
      expect(tester.widget<Text>(find.text('WhatsApp')).maxLines, 1);
      expect(tester.widget<Text>(find.text('WhatsApp')).overflow,
          TextOverflow.ellipsis);
      expect(
          find.descendant(
              of: socialAppRow('youtube'), matching: find.text('Comments and chats')),
          findsOneWidget);

      final telegramTop =
          tester.getTopLeft(socialAppRow('telegram')).dy;
      final whatsappTop =
          tester.getTopLeft(socialAppRow('whatsapp')).dy;
      final youtubeTop =
          tester.getTopLeft(socialAppRow('youtube')).dy;
      expect(telegramTop, lessThan(whatsappTop));
      expect(whatsappTop, lessThan(youtubeTop));

      await tester.tap(find.text('Not on Alex\'s phone (9)'));
      await tester.pumpAndSettle();
      expect(socialAppRow('reddit'), findsOneWidget);
      await chooseSocialApp(tester, 'reddit', on: false);
      expect(socialAppOn(tester, 'reddit'), isFalse);
    });

    // P-17 (`#1179`): the row states what the phone reports, never the promise a switch used to imply.
    testWidgets('the row states the phone\'s own word for the check', (tester) async {
      Map<String, dynamic> familyWithStates(List<String> states) => {
            ...familyMeTwoChildren(),
            'devices': [
              for (var i = 0; i < states.length; i++)
                {
                  'id': 'dev-${i + 1}',
                  'childId': 'child-1',
                  'platform': 'android',
                  'model': 'Galaxy S23',
                  'osVersion': '14',
                  'status': 'online',
                  'batteryPct': 55,
                  'setup': {
                    'reportedAt': '2026-11-26T05:00:00.000Z',
                    'features': {'notification_scan': states[i]},
                    'missing': <String>[],
                  },
                },
            ],
          };
      Map<String, dynamic> familyWith(String state) => familyWithStates([state]);

      await pumpScreen(tester, const SocialScreen(childId: 'child-1'),
          FakeApiClient(socialRoutes(familyMe: familyWith('degraded'))), tall: true);
      await flushFakeHttp(tester);
      expect(
          tester.widget<Text>(find.byKey(const ValueKey('socialAppState-whatsapp'))).data,
          'Limited');

      await pumpScreen(tester, const SocialScreen(childId: 'child-1'),
          FakeApiClient(socialRoutes(familyMe: familyWith('not_supported'))), tall: true);
      await flushFakeHttp(tester);
      expect(
          tester.widget<Text>(find.byKey(const ValueKey('socialAppState-whatsapp'))).data,
          'Not in this version');

      // Ahmed's point 1 (14:16): a phone that reports `ready` said so; "Checking" is for a phone that has
      // not reported at all. Mutant: drop the `'ready'` case and this row reads "Checking".
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'),
          FakeApiClient(socialRoutes(familyMe: familyWith('ready'))), tall: true);
      await flushFakeHttp(tester);
      expect(
          tester.widget<Text>(find.byKey(const ValueKey('socialAppState-whatsapp'))).data,
          'Ready');

      // Ahmed's point 2: two phones, one ready and one degraded. The row shows the weakest, never "Ready"
      // while another of the child's phones cannot scan. Mutant: take the first report and this reads
      // "Ready".
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'),
          FakeApiClient(socialRoutes(
              familyMe: familyWithStates(['ready', 'degraded']))),
          tall: true);
      await flushFakeHttp(tester);
      expect(
          tester.widget<Text>(find.byKey(const ValueKey('socialAppState-whatsapp'))).data,
          'Limited',
          reason: 'the weakest reported phone decides the row');
    });

    // P-17 / Fix 8: an iPhone child's messages are not scanned, and the section says so instead of listing rows.
    testWidgets('an iPhone-only child sees the not-yet line and no app rows', (tester) async {
      final family = {
        ...familyMeTwoChildren(),
        'devices': [
          {
            'id': 'dev-ios',
            'childId': 'child-1',
            'platform': 'ios',
            'model': 'iPhone 13',
            'osVersion': '18',
            'status': 'online',
            'batteryPct': 70,
            'setup': {
              'reportedAt': '2026-11-26T05:00:00.000Z',
              'features': <String, String>{},
              'missing': <String>[],
            },
          },
        ],
      };
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'),
          FakeApiClient(socialRoutes(familyMe: family)), tall: true);
      await flushFakeHttp(tester);

      expect(find.byKey(const ValueKey('socialIphoneNotYet')), findsOneWidget);
      expect(find.text('Not yet available on iPhone'), findsOneWidget);
      expect(socialAppRow('whatsapp'), findsNothing);
    });

    // P-17's switch: off restores the rows this screen shipped with, so the morning of a test can turn the new
    // shape off without a revert.
    testWidgets('with the switch off the section keeps its per-app switches', (tester) async {
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'),
          FakeApiClient(socialRoutes()), tall: true, uxP17: false);
      await flushFakeHttp(tester);
      expect(find.byType(SwitchListTile), findsWidgets);
      expect(find.byKey(const ValueKey('socialAppState-whatsapp')), findsNothing);
    });

    testWidgets('the four-app banner dismisses once and stays dismissed',        (tester) async {
      final api = FakeApiClient(socialRoutes());
      const banner =
          'You can now choose YouTube, Telegram, Reddit and Messenger too.';
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);
      expect(find.text(banner), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text(banner), findsNothing);

      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);
      expect(find.text(banner), findsNothing);
    });

    for (final locale in [const Locale('en'), const Locale('ar')]) {
      testWidgets(
          'Social monitoring fits 320 px at 200% text in ${locale.languageCode}',
          (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final api = FakeApiClient(socialRoutes(
          installedApps: socialInventory({'whatsapp', 'youtube'}, true),
        ));
        await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
            locale: locale, frameBoundary: true);
        await flushFakeHttp(tester);

        for (final appKey in ['whatsapp', 'youtube']) {
          final image = tester.widget<Image>(find.descendant(
            of: find.byKey(ValueKey('socialAppRow-$appKey')),
            matching: find.byType(Image),
          ));
          expect(image.image, isA<MemoryImage>(),
              reason: '$appKey must render its reported launcher icon');
        }
        if (locale.languageCode == 'ar') {
          expect(find.text('فحص الرسائل في هذه التطبيقات'), findsOneWidget);
          expect(find.textContaining('غير مثبّتة على هاتف'), findsOneWidget);
          expect(find.text('التعليقات والمحادثات'), findsOneWidget);
          expect(
              find.text(
                  'لا ينبّهك تطبيق أسرة للأطفال إلا إلى الرسائل التي تستدعي المراجعة، ولا يعرض لك كل المحادثات أبدًا.'),
              findsOneWidget);
        } else {
          expect(find.text('Check messages in'), findsOneWidget);
          expect(find.text('Not on Alex\'s phone (10)'), findsOneWidget);
          expect(find.text('Comments and chats'), findsOneWidget);
          expect(
              find.text(
                  'OSRA only flags concerning messages. It never shows you every chat.'),
              findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await maybeCaptureFrame(
            tester, 'social-${locale.languageCode}-320-200.png');
      });
    }

    testWidgets('empty socialMonitoring map ({}) parses empty in RuleSet and renders all apps ON (#1024)', (tester) async {
      expect(RuleSet.fromJson(const {'socialMonitoring': {}}).socialMonitoring, isEmpty);
      expect(RuleSet.fromJson(const {}).socialMonitoring, isEmpty);

      final api = FakeApiClient(socialRoutes(socialMonitoring: const {}));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api, tall: true);
      await flushFakeHttp(tester);

      for (final a in kSocialApps) {
        await reveal(tester, socialAppRow(a.appKey));
        expect(socialAppOn(tester, a.appKey), isTrue, reason: '${a.label} should render ON for {}');
      }
    });

    testWidgets('flip + save PUTs the merged socialMonitoring map',
        (tester) async {
      final api =
          FakeApiClient(socialRoutes(socialMonitoring: {'whatsapp': true}));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      await chooseSocialApp(tester, 'whatsapp', on: false);
      await tester.tap(find.text('Save monitoring'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      final social = Map<String, dynamic>.from(
          puts.single.body['socialMonitoring'] as Map);
      expect(social['whatsapp'], isFalse);
      expect(social['twitter'], isTrue);
      expect(social.containsKey('x'), isFalse);
      expect(social.keys, hasLength(kSocialApps.length));
      expect(
          puts.single.body.keys,
          containsAll([
            'screenTime',
            'webFilter',
            'appRules',
            'routines',
            'socialMonitoring'
          ]));
      expect(find.text('Monitoring saved'), findsOneWidget);
    });

    testWidgets('saving X writes twitter and removes the legacy x shadow key',
        (tester) async {
      final api = FakeApiClient(socialRoutes(socialMonitoring: {'x': true}));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);
      await chooseSocialApp(tester, 'twitter', on: false);
      await tester.tap(find.text('Save monitoring'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final social = Map<String, dynamic>.from(api
          .calls('PUT', '/v1/rules/child-1')
          .single
          .body['socialMonitoring'] as Map);
      expect(social['twitter'], isFalse);
      expect(social.containsKey('x'), isFalse);
    });
  });

  group('Concerns vault', () {
    testWidgets('pull-to-refresh reloads concerns even when the list fits',
        (tester) async {
      final pending = Completer<Object?>();
      var refreshRequested = false;
      final api = FakeApiClient({
        ...socialRoutes(),
        'GET /v1/social/events': (_) => refreshRequested
            ? FakeDeferred(pending.future)
            : {
                'items': [concernJson()]
              },
      });
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      final scrollPosition =
          tester.state<ScrollableState>(socialScrollable()).position;
      expect(scrollPosition.maxScrollExtent, 0);
      expect(find.text('Maya'), findsOneWidget);
      expect(api.calls('GET', '/v1/social/events'), hasLength(1));
      final activityRequestCount = api.calls('GET', '/v1/reports/activity').length;

      refreshRequested = true;
      final list = find.byKey(const ValueKey('socialSectionsList'));
      await tester.dragFrom(tester.getTopLeft(list) + const Offset(40, 24),
          const Offset(0, 620));
      await tester.pump();
      await flushFakeHttp(tester);
      final wasRefreshing =
          find.byType(RefreshProgressIndicator).evaluate().isNotEmpty;
      pending.complete({
        'items': [concernJson(id: 'se-new', contact: 'Lina'), concernJson()],
      });
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final requests = api.calls('GET', '/v1/social/events');
      expect(requests.map((request) => request.query['childId']),
          ['child-1', 'child-1']);
      expect(api.calls('GET', '/v1/reports/activity'),
          hasLength(activityRequestCount));
      expect(wasRefreshing, isTrue);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(find.text('Lina'), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
    });

    testWidgets(
        'renders severity-colored cards with concern chips and an expandable preview',
        (tester) async {
      final api = FakeApiClient(socialRoutes(concerns: [concernJson()]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('Maya'));
      expect(find.text('Maya'), findsOneWidget);
      expect(find.text('Grooming'), findsOneWidget);
      expect(find.text('Late at night'), findsOneWidget);
      expect(find.textContaining('WhatsApp · '), findsOneWidget);
      // Severity tint on the card + colored leading icon.
      final card =
          find.ancestor(of: find.text('Maya'), matching: find.byType(Card));
      expect(tester.widget<Card>(card).color, isNotNull);

      const preview = 'Are you coming tonight? Don\'t tell your parents.';
      expect(find.text(preview), findsNothing);
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      expect(find.text(preview), findsOneWidget);

      // Verify View in Decryption Vault button opens the vault modal
      expect(find.text('View in Decryption Vault'), findsOneWidget);
      await tester.tap(find.text('View in Decryption Vault'));
      await tester.pumpAndSettle();
      expect(find.text('Encrypted Family Vault'), findsOneWidget);
      expect(find.text('Decrypted content'), findsOneWidget);
    });

    testWidgets(
        'list vote POSTs once and the vault reuses the selected event vote',
        (tester) async {
      // Mutant: omitting eventId from the vault or posting to the alert id leaves
      // the two surfaces out of sync and writes feedback for the wrong resource.
      final api = FakeApiClient({
        ...socialRoutes(concerns: [concernJson()]),
        'POST /v1/social/events/se-1/feedback': (request) => {
              'feedback': {
                'verdict': request.body['verdict'],
                'parentDisplayName': 'QA Parent',
                'firstVotedAt': '2026-11-24T10:01:00.000Z',
                'lastChangedAt': '2026-11-24T10:01:00.000Z',
              },
            },
        'DELETE /v1/social/events/se-1/feedback': (_) => {'feedback': null},
      });
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      await reveal(tester, find.byTooltip('Mark as concerning'));
      final voteButtonSize = tester.getSize(find.byTooltip('Mark as concerning'));
      expect(voteButtonSize.width, greaterThanOrEqualTo(48));
      expect(voteButtonSize.height, greaterThanOrEqualTo(48));
      expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsOneWidget);
      expect(
          find.widgetWithText(OutlinedButton, 'Not concerning'), findsOneWidget);
      await tester.tap(find.byTooltip('Mark as concerning'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('POST', '/v1/social/events/se-1/feedback').single.body,
          {'verdict': 'concerning'});
      expect(find.widgetWithText(FilledButton, 'Concerning'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View in Decryption Vault'));
      await tester.pumpAndSettle();
      expect(find.text('Was OSRA right to flag this?'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Concerning'), findsNWidgets(2));
      expect(find.text('Thanks, noted'), findsNothing);
    });

    testWidgets(
        'U100: tapping the cast vote chip on a 390px concern card reopens both choices without overflow and switches vote',
        (tester) async {
      // Mutant: keeping _editing only inside SocialVoteControls without lifting
      // it into _ConcernCard either overflows the 390px Row or drops _editing
      // when moving from title to subtitle, preventing the Not concerning tap.
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final api = FakeApiClient({
        ...socialRoutes(concerns: [concernJson()]),
        'POST /v1/social/events/se-1/feedback': (request) => {
              'feedback': {
                'verdict': request.body['verdict'],
                'parentDisplayName': 'QA Parent',
                'firstVotedAt': '2026-11-24T10:01:00.000Z',
                'lastChangedAt': '2026-11-24T10:02:00.000Z',
              },
            },
      });
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      await reveal(tester, find.widgetWithText(OutlinedButton, 'Concerning'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Concerning'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('POST', '/v1/social/events/se-1/feedback').single.body,
          {'verdict': 'concerning'});
      final chip = find.widgetWithText(FilledButton, 'Concerning');
      expect(chip, findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final notConcerning =
          find.widgetWithText(OutlinedButton, 'Not concerning');
      expect(notConcerning, findsOneWidget);

      await tester.tap(notConcerning);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      final posts = api.calls('POST', '/v1/social/events/se-1/feedback');
      expect(posts, hasLength(2));
      expect(posts.last.body, {'verdict': 'not_concerning'});
      expect(
          find.widgetWithText(FilledButton, 'Not concerning'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets(
        'the latest co-parent vote and isolated voter name render while own choices are unset',
        (tester) async {
      final api = FakeApiClient(socialRoutes(concerns: [
        concernJson(latestFeedback: {
          'verdict': 'not_concerning',
          'parentDisplayName': 'Lina',
          'firstVotedAt': '2026-11-24T10:01:00.000Z',
          'lastChangedAt': '2026-11-24T10:02:00.000Z',
        }),
      ]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
          tall: true);
      await flushFakeHttp(tester);

      await reveal(tester, find.byTooltip('Mark as not concerning'));
      expect(find.byTooltip('Mark as not concerning'), findsOneWidget);
      expect(find.text('\u2068Lina\u2069: Not concerning'), findsOneWidget);
    });

    for (final locale in [const Locale('en'), const Locale('ar')]) {
      testWidgets(
          'concern vote controls move below text at 320px/200% in ${locale.languageCode}',
          (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final api = FakeApiClient(socialRoutes(concerns: [concernJson()]));
        await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
            locale: locale);
        await flushFakeHttp(tester);

        final tooltip = locale.languageCode == 'ar'
            ? 'اعتبار الرسالة مقلقة'
            : 'Mark as concerning';
        await reveal(tester, find.byTooltip(tooltip));
        expect(tester.getTopLeft(find.byTooltip(tooltip)).dy,
            greaterThan(tester.getRect(find.text('Maya')).bottom));
        expect(tester.takeException(), isNull);
      });
    }

    for (final locale in [const Locale('en'), const Locale('ar')]) {
      testWidgets(
          'localized Social concern chips fit 320 px at 200% in ${locale.languageCode}',
          (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final api = FakeApiClient(socialRoutes(concerns: [concernJson()]));
        await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api,
            locale: locale, frameBoundary: true);
        await flushFakeHttp(tester);

        final card = find.byKey(const ValueKey('se-1'));
        await reveal(tester, card);
        final labels = locale.languageCode == 'ar'
            ? ['استدراج', 'في وقت متأخر ليلًا']
            : ['Grooming', 'Late at night'];
        for (final label in labels) {
          final chip =
              find.ancestor(of: find.text(label), matching: find.byType(Chip));
          expect(chip, findsOneWidget);
          expect(tester.getRect(chip).left,
              greaterThanOrEqualTo(tester.getRect(card).left));
          expect(tester.getRect(chip).right,
              lessThanOrEqualTo(tester.getRect(card).right));
        }
        expect(find.text('grooming_risk'), findsNothing);
        expect(find.text('late_night'), findsNothing);
        expect(tester.takeException(), isNull);
        await maybeCaptureFrame(
            tester, 'social-concern-labels-${locale.languageCode}-320-200.png');
      });
    }

    testWidgets('shows the empty state when there are no concerns',
        (tester) async {
      final api = FakeApiClient(socialRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('No concerns detected'));
      expect(find.text('No concerns detected'), findsOneWidget);
    });
  });

  group('Contact allowlist', () {
    testWidgets('add normalizes digits and save PUTs contactAllowlist',
        (tester) async {
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

    testWidgets('Arabic digits are the same phone number (#771)',
        (tester) async {
      final api = FakeApiClient(socialRoutes(contactAllowlist: const []));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final phoneField = fieldByLabel('Phone number');
      await reveal(tester, phoneField);
      await tester.enterText(phoneField, '+١ (٥٥٥) ١٢٣-٤٥٦٧');
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(find.text('15551234567'), findsOneWidget);
      expect(find.text('+١ (٥٥٥) ١٢٣-٤٥٦٧'), findsNothing);
    });

    testWidgets('removing a chip and saving PUTs the updated contactAllowlist',
        (tester) async {
      final api = FakeApiClient(
          socialRoutes(contactAllowlist: ['15550001122', '15553334445']));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('15550001122'));
      tester
          .widget<InputChip>(find.widgetWithText(InputChip, '15550001122'))
          .onDeleted!();
      await tester.pumpAndSettle();
      expect(find.text('15550001122'), findsNothing);

      await reveal(tester, find.text('Save allowlist'));
      await tester.tap(find.text('Save allowlist'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(
          api.calls('PUT', '/v1/rules/child-1').single.body['contactAllowlist'],
          ['15553334445']);
    });
  });

  group('Phone calls & texts timeline (#6)', () {
    /// Seeds the timeline on [base]'s local calendar day: the recent call and
    /// the SMS sit on that day, the older call on the previous one, whatever
    /// [base]'s time of day. Built from calendar fields — never `base ±
    /// Duration` — so a 00:00 or 23:59 fixture cannot cross a day boundary
    /// (issue #176).
    Map<String, FakeRoute> timelineRoutes(DateTime base) {
      final yesterday =
          DateTime(base.year, base.month, base.day - 1, base.hour, base.minute);
      final smsAt = DateTime(base.year, base.month, base.day, 12, 30);
      return socialRoutes(
        calls: [
          callJson(
              direction: 'outgoing',
              durationSec: 95,
              at: DateTime(
                  base.year, base.month, base.day, base.hour, base.minute)),
          callJson(
              id: 'act-call-2',
              number: '+15550002222',
              direction: 'incoming',
              durationSec: 12,
              at: yesterday),
        ],
        sms: [smsJson(bodyPreview: 'x' * 200, at: smsAt)],
      );
    }

    Future<void> expectDayGroupedTimeline(
        WidgetTester tester, DateTime base) async {
      await reveal(tester, find.byIcon(Icons.call_made));
      expect(find.byIcon(Icons.call_made), findsOneWidget);
      expect(find.byIcon(Icons.call_received), findsOneWidget);
      expect(find.byIcon(Icons.sms_outlined), findsOneWidget);
      expect(find.text('\u2066+15551234567\u2069'), findsOneWidget);
      expect(find.text('01:35'), findsOneWidget);
      expect(find.text('00:12'), findsOneWidget);
      // 200-char body is capped at 120 chars.
      expect(find.text('${'x' * 120}…'), findsOneWidget);
      // Day groups: today and yesterday headers.
      final today = DateFormat.yMMMMEEEEd()
          .format(DateTime(base.year, base.month, base.day));
      final yesterday = DateFormat.yMMMMEEEEd()
          .format(DateTime(base.year, base.month, base.day - 1));
      expect(find.text(today), findsOneWidget);
      await reveal(tester, find.text(yesterday));
      expect(find.text(yesterday), findsOneWidget);
    }

    testWidgets(
        'renders call rows (direction icon, mm:ss) and sms rows (120-char preview), day-grouped',
        (tester) async {
      final api = FakeApiClient(timelineRoutes(testNow));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await expectDayGroupedTimeline(tester, testNow);
    });

    for (final boundary in [
      DateTime(2026, 10, 19, 0, 0),
      DateTime(2026, 10, 19, 23, 59)
    ]) {
      final label = DateFormat('HH:mm').format(boundary);
      testWidgets(
          'groups today and yesterday with the fixture base pinned at $label local',
          (tester) async {
        final api = FakeApiClient(timelineRoutes(boundary));
        await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
        await flushFakeHttp(tester);

        await expectDayGroupedTimeline(tester, boundary);
      });
    }

    testWidgets('shows the empty state and the iOS NOTE', (tester) async {
      final api = FakeApiClient(socialRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('No phone calls or texts yet'));
      expect(find.text('No phone calls or texts yet'), findsOneWidget);
      expect(find.text('iOS does not support phone-call or text monitoring.'),
          findsOneWidget);
    });

    testWidgets('fetches type=call and type=sms and merges newest-first',
        (tester) async {
      final api = FakeApiClient(socialRoutes(
        calls: [callJson(at: testNow.subtract(const Duration(minutes: 5)))],
        sms: [smsJson(at: testNow.subtract(const Duration(minutes: 1)))],
      ));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final gets = api.calls('GET', '/v1/reports/activity');
      expect(gets, hasLength(3));
      expect(gets.map((r) => r.query['type']),
          containsAll(['call', 'sms', 'lock_period']));
      expect(find.text('Device locked'), findsNothing);

      // Newest (sms, 1 min ago) renders above the older call.
      await reveal(tester, find.text('running late, see you at 5'));
      final smsTop = tester.getTopLeft(find.byIcon(Icons.sms_outlined));
      final callTop = tester.getTopLeft(find.byIcon(Icons.call_made));
      expect(smsTop.dy, lessThan(callTop.dy));
    });

    testWidgets('a lock period renders with the attempt count (#830)',
        (tester) async {
      final api = FakeApiClient(socialRoutes(locks: [
        {
          'id': 'lock-1',
          'type': 'lock_period',
          'payload': {
            'startedAt': '2026-11-15T18:00:00.000Z',
            'endedAt': '2026-11-15T18:20:00.000Z',
            'attempts': 5,
            'mode': 'locked',
          },
          'ts': testNow.subtract(const Duration(minutes: 2)).toIso8601String(),
        },
      ]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      await reveal(tester, find.text('Device locked'));
      expect(find.text('Device locked'), findsOneWidget);
      expect(find.text('The lock screen came up 5 times'), findsOneWidget);
    });
  });

  group('Child detail Social tab', () {
    testWidgets(
        'embeds the social sections and the Overview entry jumps to the tab',
        (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(
          tester, const ChildDetailScreen(childId: 'child-1'), api);

      // Overview entry ListTile with chevron.
      expect(find.text('Social monitoring'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.text('Social'));
      await tester.pumpAndSettle();
      await flushFakeHttp(tester);

      expect(find.text('Check messages in'), findsOneWidget);
      await reveal(tester, find.text('Concerns'));
      expect(find.text('Concerns'), findsOneWidget);
      await reveal(tester, find.text('Phone calls & texts'));
      expect(find.text('Phone calls & texts'), findsOneWidget);
      await reveal(tester, find.text('Trusted contacts'));
      expect(find.text('Trusted contacts'), findsOneWidget);
      await reveal(tester, find.text('No concerns detected'));
      expect(find.text('No concerns detected'), findsOneWidget);
      await reveal(tester, find.text('No phone calls or texts yet'));
      expect(find.text('No phone calls or texts yet'), findsOneWidget);
    });
  });

  group('compact selected labels stay on one line', () {
    for (final locale in [const Locale('en'), const Locale('ar')]) {
      for (final narrow in [false, true]) {
        for (final verdict in const ['concerning', 'not_concerning']) {
          testWidgets(
              '$verdict ${locale.languageCode} ${narrow ? '320-200' : '390'}',
              (tester) async {
            final scale = narrow ? 2.0 : 1.0;
            tester.view.physicalSize =
                Size(narrow ? 320 : 390, narrow ? 1000 : 844);
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.platformDispatcher.clearTextScaleFactorTestValue();
            });
            final feedback = {
              'verdict': verdict,
              'parentDisplayName': 'QA Parent',
              'firstVotedAt': '2026-11-24T10:01:00.000Z',
              'lastChangedAt': '2026-11-24T10:02:00.000Z',
            };
            final api = FakeApiClient(socialRoutes(concerns: [
              concernJson(
                latestFeedback: feedback,
                ownFeedback: feedback,
              ),
            ]));
            await pumpScreen(
                tester, const SocialScreen(childId: 'child-1'), api,
                locale: locale);
            await flushFakeHttp(tester);

            final label = locale.languageCode == 'ar'
                ? verdict == 'concerning'
                    ? 'مقلقة'
                    : 'غير مقلقة'
                : verdict == 'concerning'
                    ? 'Concerning'
                    : 'Not concerning';
            final pill = find.widgetWithText(FilledButton, label);
            await reveal(tester, pill);
            final contactRect = tester.getRect(find.text('Maya'));
            final expectsStacked = narrow || locale.languageCode == 'en';
            if (expectsStacked) {
              expect(tester.getRect(pill).top,
                  greaterThanOrEqualTo(contactRect.bottom));
            } else {
              expect(tester.getRect(pill).top, contactRect.top);
            }
            final paragraph =
                tester.renderObject<RenderParagraph>(find.text(label));
            int countLines(Iterable<TextBox> boxes) {
              final centers =
                  boxes.map((box) => box.toRect().center.dy).toList()..sort();
              if (centers.isEmpty) return 0;
              var lines = 1;
              for (var i = 1; i < centers.length; i++) {
                if ((centers[i] - centers[i - 1]).abs() > 5 * scale) lines++;
              }
              return lines;
            }

            final lineCount = countLines(paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            ));
            var wordStart = 0;
            for (final word in label.split(' ')) {
              final wordLines = countLines(paragraph.getBoxesForSelection(
                TextSelection(
                  baseOffset: wordStart,
                  extentOffset: wordStart + word.length,
                ),
              ));
              expect(wordLines, 1, reason: '$word broke mid-word in $label');
              wordStart += word.length + 1;
            }
            if (narrow) {
              expect(lineCount, lessThanOrEqualTo(2),
                  reason: '$label used $lineCount lines at 320 px / 200%');
            } else {
              expect(lineCount, 1,
                  reason: '$label used $lineCount lines at 390 px');
            }
            final pillRect = tester.getRect(pill);
            expect(pillRect.left, greaterThanOrEqualTo(0));
            expect(pillRect.right, lessThanOrEqualTo(narrow ? 320 : 390));
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
    testWidgets(
        'a short contact keeps at least half the row at 320 px normal scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final feedback = {
        'verdict': 'not_concerning',
        'parentDisplayName': 'QA Parent',
        'firstVotedAt': '2026-11-24T10:01:00.000Z',
        'lastChangedAt': '2026-11-24T10:02:00.000Z',
      };
      final api = FakeApiClient(socialRoutes(concerns: [
        concernJson(
          contact: 'I',
          latestFeedback: feedback,
          ownFeedback: feedback,
        ),
      ]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final pill = find.widgetWithText(FilledButton, 'Not concerning');
      await reveal(tester, pill);
      final contact = find.descendant(
        of: find.ancestor(of: pill, matching: find.byType(Card)),
        matching: find.text('I'),
      );
      expect(tester.getRect(pill).top,
          greaterThanOrEqualTo(tester.getRect(contact).bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short contact receives half the shared row at 390 px',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final feedback = {
        'verdict': 'not_concerning',
        'parentDisplayName': 'QA Parent',
        'firstVotedAt': '2026-11-24T10:01:00.000Z',
        'lastChangedAt': '2026-11-24T10:02:00.000Z',
      };
      final api = FakeApiClient(socialRoutes(concerns: [
        concernJson(
          contact: 'I',
          latestFeedback: feedback,
          ownFeedback: feedback,
        ),
      ]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final pill = find.widgetWithText(FilledButton, 'Not concerning');
      await reveal(tester, pill);
      final card = find.ancestor(of: pill, matching: find.byType(Card));
      final contact = find.descendant(of: card, matching: find.text('I'));
      final contactRow = find.ancestor(of: contact, matching: find.byType(Row));
      final contactAllocation = contactRow.evaluate().isNotEmpty
          ? tester.getRect(contactRow).width - tester.getRect(pill).width - 8
          : tester
              .getRect(find
                  .ancestor(of: contact, matching: find.byType(Column))
                  .first)
              .width;
      final expectedMinimum = (tester.getRect(card).width - 128) / 2;
      expect(contactAllocation, greaterThanOrEqualTo(expectedMinimum),
          reason: 'Contact received $contactAllocation px of the shared row; '
              'it needs at least $expectedMinimum px');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long contact stacks the trailing pill at 390 px',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const contact = 'A very long contact name that needs the full row';
      final feedback = {
        'verdict': 'not_concerning',
        'parentDisplayName': 'QA Parent',
        'firstVotedAt': '2026-11-24T10:01:00.000Z',
        'lastChangedAt': '2026-11-24T10:02:00.000Z',
      };
      final api = FakeApiClient(socialRoutes(concerns: [
        concernJson(
          contact: contact,
          latestFeedback: feedback,
          ownFeedback: feedback,
        ),
      ]));
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final pill = find.widgetWithText(FilledButton, 'Not concerning');
      await reveal(tester, pill);
      expect(tester.getRect(pill).top,
          greaterThanOrEqualTo(tester.getRect(find.text(contact)).bottom));
      expect(tester.takeException(), isNull);
    });
  });

  group('Bureau vote frames (writes only with OSRA_FRAME_DIR)', () {
    Map<String, dynamic> feedback(String verdict, String name) => {
          'verdict': verdict,
          'parentDisplayName': name,
          'firstVotedAt': '2026-11-24T10:01:00.000Z',
          'lastChangedAt': '2026-11-24T10:02:00.000Z',
        };

    Map<String, dynamic> frameConcern(String state) {
      final selected = state == 'concerning' || state == 'not_concerning';
      return concernJson(
        latestFeedback: switch (state) {
          'unset' => null,
          'cleared' => feedback('concerning', 'Lina'),
          _ => feedback(state, 'QA Parent'),
        },
        ownFeedback: selected ? feedback(state, 'QA Parent') : null,
      );
    }

    for (final locale in [const Locale('en'), const Locale('ar')]) {
      for (final narrow in [false, true]) {
        for (final dark in [false, true]) {
          testWidgets(
              'Social Monitoring ${locale.languageCode} ${narrow ? '320-200' : '390'} ${dark ? 'dark' : 'light'}',
              (tester) async {
            for (final state in const [
              'unset',
              'concerning',
              'not_concerning',
              'cleared',
            ]) {
              tester.view.physicalSize =
                  Size(narrow ? 320 : 390, narrow ? 1000 : 844);
              tester.view.devicePixelRatio = 1;
              tester.platformDispatcher.textScaleFactorTestValue =
                  narrow ? 2 : 1;
              addTearDown(() {
                tester.view.resetPhysicalSize();
                tester.view.resetDevicePixelRatio();
                tester.platformDispatcher.clearTextScaleFactorTestValue();
              });
              final api =
                  FakeApiClient(socialRoutes(concerns: [frameConcern(state)]));
              await pumpScreen(
                tester,
                const SocialScreen(childId: 'child-1'),
                api,
                locale: locale,
                frameBoundary: true,
                dark: dark,
              );
              await flushFakeHttp(tester);

              final target = switch (state) {
                'concerning' => find.widgetWithText(FilledButton,
                    locale.languageCode == 'ar' ? 'مقلقة' : 'Concerning'),
                'not_concerning' => find.widgetWithText(
                    FilledButton,
                    locale.languageCode == 'ar'
                        ? 'غير مقلقة'
                        : 'Not concerning'),
                _ => find.byTooltip(locale.languageCode == 'ar'
                    ? 'اعتبار الرسالة مقلقة'
                    : 'Mark as concerning'),
              };
              await reveal(tester, target);
              await tester.ensureVisible(find.text('Maya'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await maybeCaptureFrame(
                tester,
                'social-monitoring-vote-$state-${locale.languageCode}-${dark ? 'dark' : 'light'}-${narrow ? '320-200' : '390'}.png',
              );
              await tester.pumpWidget(const SizedBox());
            }
          });
        }
      }
    }
  });

  group('Arabic dates', () {
    testWidgets('the day header follows the locale order with Western digits',
        (tester) async {
      await configureDateFormatting();
      final api = FakeApiClient(
          socialRoutes(calls: [callJson(at: DateTime.utc(2026, 11, 14, 12))]));
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const SocialScreen(childId: 'child-1'),
            locale: const Locale('ar')),
      ));
      await tester.pumpAndSettle();
      await flushFakeHttp(tester);

      await reveal(tester, find.text('السبت، 14 نوفمبر 2026'));
    });
  });
}
