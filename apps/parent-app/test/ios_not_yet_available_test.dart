import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #1088 (epic #1092): on 24 Nov the iPhone child acked Ring, Lock and Pause internet as `not_supported`
/// within seconds, while the parent app still showed working buttons. The controls are now drawn
/// "Not yet available" from the server's `setup.unsupportedCommands`, never from the platform name, and a
/// tap explains why without sending anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const iosUnsupported = [
    'lock',
    'unlock',
    'pause',
    'resume',
    'pause_internet',
    'resume_internet',
    'ring',
    'stop_ring',
  ];

  Map<String, dynamic> familyWith({required String platform, required List<String> unsupported}) {
    final base = familyMeTwoChildren(alexPlatform: platform, alexModel: platform == 'ios' ? 'iPhone 13' : 'Pixel 7a');
    final devices = [
      for (final d in (base['devices'] as List).cast<Map<String, dynamic>>())
        d['id'] == 'dev-1'
            ? {
                ...d,
                'setup': {
                  'reportedAt': DateTime.now().toUtc().toIso8601String(),
                  'stale': false,
                  'features': <String, String>{},
                  'missing': <String>[],
                  'profiles': null,
                  'groups': null,
                  'unsupportedCommands': unsupported,
                },
              }
            : d,
    ];
    return {...base, 'devices': devices};
  }

  Future<FakeApiClient> pump(WidgetTester tester, Map<String, dynamic> familyMe) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = FakeApiClient({...standardRoutes(familyMe: familyMe)});
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('an iPhone child: the four controls say "Not yet available" and the card line names them',
      (tester) async {
    await pump(tester, familyWith(platform: 'ios', unsupported: iosUnsupported));

    // Ring, Stop ring, Lock, Unlock, Pause device and Pause internet each carry the pill.
    expect(find.text('Not yet available'), findsNWidgets(6));
    expect(find.byKey(const ValueKey('notYetCardLine-dev-1')), findsOneWidget);
    expect(
      find.text("On Alex's iPhone, Lock, Pause device, Pause internet and Ring aren't available yet."),
      findsOneWidget,
    );
    // K31 on #1123: the card promises nothing the phone's capability report does not back.
    expect(find.textContaining('work now'), findsNothing);
  });

  testWidgets('a tap on a not-yet control explains why and never sends a command', (tester) async {
    final api = await pump(tester, familyWith(platform: 'ios', unsupported: iosUnsupported));

    await tester.ensureVisible(find.byKey(const ValueKey('deviceAction-ring-dev-1')));
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('deviceAction-ring-dev-1')),
      matching: find.bySubtype<ButtonStyleButton>(),
    ));
    await tester.pump();

    expect(find.text("Ring isn't available on iPhone yet. It will arrive in an app update."), findsOneWidget);
    expect(api.requests.where((r) => r.method == 'POST' && r.path.contains('/command')), isEmpty,
        reason: 'a not-yet control must never queue a command the build will refuse');
  });

  testWidgets('the buttons follow the server: an iPhone build that can ring shows Ring as usual', (tester) async {
    // When #760 lands, the table drops ring/stop_ring and the button returns with no app change.
    await pump(
      tester,
      familyWith(platform: 'ios', unsupported: iosUnsupported.where((c) => c != 'ring' && c != 'stop_ring').toList()),
    );

    expect(find.text('Not yet available'), findsNWidgets(4));
    expect(
      find.text("On Alex's iPhone, Lock, Pause device and Pause internet aren't available yet."),
      findsOneWidget,
    );
  });

  testWidgets('an Android child keeps every control and has no card line', (tester) async {
    await pump(tester, familyWith(platform: 'android', unsupported: const []));

    expect(find.text('Not yet available'), findsNothing);
    expect(find.byKey(const ValueKey('notYetCardLine-dev-1')), findsNothing);
    expect(find.text('Ring'), findsWidgets);
    expect(find.text('Pause internet'), findsOneWidget);
  });

  group('#1088 review: the child-wide Pause internet', () {
    Map<String, dynamic> withSetup(Map<String, dynamic> base, String deviceId, List<String> unsupported) => {
          ...base,
          'devices': [
            for (final d in (base['devices'] as List).cast<Map<String, dynamic>>())
              d['id'] == deviceId
                  ? {
                      ...d,
                      'setup': {
                        'reportedAt': DateTime.now().toUtc().toIso8601String(),
                        'stale': false,
                        'features': <String, String>{},
                        'missing': <String>[],
                        'unsupportedCommands': unsupported,
                      },
                    }
                  : d,
          ],
        };

    Future<FakeApiClient> pumpDashboard(WidgetTester tester, Map<String, dynamic> familyMe) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final api = FakeApiClient({
        ...standardRoutes(familyMe: familyMe),
        'GET /v1/controls/children/child-1/status': (_) => {'paused': false},
        'GET /v1/controls/children/child-2/status': (_) => {'paused': false},
        'POST /v1/controls/children/child-1/pause': (_) => {'ok': true},
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const DashboardScreen()),
      ));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('an iPhone-only child: the dashboard pill says Not yet available and never pauses', (tester) async {
      final api = await pumpDashboard(
        tester,
        withSetup(familyMeTwoChildren(alexPlatform: 'ios', alexModel: 'iPhone 13'), 'dev-1', iosUnsupported),
      );

      expect(find.byKey(const ValueKey('internetPillNotYet-child-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('internetPillNotYet-child-1')));
      await tester.pump();

      expect(find.text("Pause internet isn't available on iPhone yet. It will arrive in an app update."), findsOneWidget);
      expect(find.text('Pause internet for Alex?'), findsNothing, reason: 'no confirm dialog for a pause that cannot apply');
      expect(api.requests.where((r) => r.method == 'POST' && r.path.contains('/controls/')), isEmpty);
      expect(find.text('Paused'), findsNothing, reason: "Karim's 24 Nov failure: the pill must not flip to Paused");
    });

    testWidgets('an iPhone and an Android: the dialog names the skipped iPhone, and the pause still goes out',
        (tester) async {
      final api = await pumpDashboard(tester, withSetup(familyMeMixedDevices(), 'dev-1', iosUnsupported));

      expect(find.byKey(const ValueKey('internetPillNotYet-child-1')), findsNothing,
          reason: 'the Android tablet can pause, so the pill works');
      final alexCard = find.ancestor(of: find.text('Alex'), matching: find.byType(Card));
      await tester.tap(find.descendant(of: alexCard, matching: find.text('Internet')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('pauseInternetSkipsLine')), findsOneWidget);
      expect(find.text("iPhone 13 can't pause the internet yet, so it stays online."), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Pause'));
      await tester.pumpAndSettle();
      expect(api.requests.where((r) => r.method == 'POST' && r.path == '/v1/controls/children/child-1/pause'),
          hasLength(1));
    });
  });
}
