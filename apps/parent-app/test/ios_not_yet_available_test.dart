import 'package:familyshield_parent/features/children/child_detail_screen.dart';
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
      find.text("On Alex's iPhone, Lock, Pause device, Pause internet and Ring aren't available yet. "
          'Screen-time limits, app blocking and the web filter work now.'),
      findsOneWidget,
    );
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
      find.text("On Alex's iPhone, Lock, Pause device and Pause internet aren't available yet. "
          'Screen-time limits, app blocking and the web filter work now.'),
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
}
