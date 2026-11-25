import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/app.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/providers/social_provider.dart';
import 'package:familyshield_parent/push/background_push.dart';
import 'package:familyshield_parent/push/foreground_push.dart';
import 'package:familyshield_parent/push/notification_tap.dart';

import 'fake_api_client.dart';

final _realtimeEffectsProvider =
    Provider<RealtimeEffects>((ref) => RealtimeEffects.fromRef(ref));

void main() {
  const socialRoute = '/child/child-1/social';
  late FakeApiClient api;
  late ProviderContainer container;
  late bool hasNewConcern;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'jwt': 'fixture-session'});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
    notificationTapController.clear();
    hasNewConcern = false;
    Map<String, String> concern(String id, String contact) => {
          'id': id,
          'app': 'whatsapp',
          'contact': contact,
          'severity': 'warning',
        };
    api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/social/events': (_) => {
            'items': [
              if (hasNewConcern) concern('newer', 'Recent sender'),
              concern('older', 'First sender'),
            ],
          },
    });
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      wsProvider.overrideWith((_) async => null),
    ]);
    addTearDown(container.dispose);
  });

  Future<void> openSocial(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const FamilyShieldApp(),
    ));
    await tester.pumpAndSettle();
    router.go(socialRoute);
    await tester.pumpAndSettle();
    expect(find.text('First sender'), findsOneWidget);
    expect(find.text('Recent sender'), findsNothing);
    hasNewConcern = true;
  }

  testWidgets('foreground APNs alert refreshes the open concerns',
      (tester) async {
    await openSocial(tester);
    final messages = StreamController<Map<String, dynamic>>();
    final subscription = await enablePushAlerts<Map<String, dynamic>>(
      ensureFirebaseInitialized: () async {},
      registerBackgroundHandler: () {},
      configureForegroundPresentation: () async {},
      foregroundMessages: messages.stream,
      openedMessageData: const Stream.empty(),
      readInitialMessageData: () async => null,
      isApplePlatform: true,
      hasNotificationPayload: (_) => true,
      extractData: (message) => message,
      runWake: () async => WakeOutcome.nothingNew,
    );
    addTearDown(() async {
      await subscription?.cancel();
      await messages.close();
    });

    expect(subscription, isNotNull);
    final requestsBefore = api.calls('GET', '/v1/social/events').length;
    messages.add(const {'w': '1'});
    // Riverpod schedules a scope rebuild, then fake Dio handles the request.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(
        api.calls('GET', '/v1/social/events'), hasLength(requestsBefore + 1));
    expect(find.text('Recent sender'), findsOneWidget);
  });

  testWidgets('returning to the foreground refreshes the open concerns',
      (tester) async {
    await openSocial(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('Recent sender'), findsOneWidget);
  });

  testWidgets('opening a generic notification clears the stale concerns cache',
      (tester) async {
    await openSocial(tester);
    await handleFcmNotificationTap(const {'w': '1'},
        fetchAlerts: () async => []);
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/alerts');
    router.go(socialRoute);
    await tester.pumpAndSettle();
    expect(find.text('Recent sender'), findsOneWidget);
  });

  testWidgets('a social realtime alert refreshes only the matching child',
      (tester) async {
    final other = container.listen(socialEventsProvider('child-2'), (_, __) {});
    addTearDown(other.close);
    await openSocial(tester);
    final input = container.read(_realtimeEffectsProvider);
    final requestsBefore = api.calls('GET', '/v1/social/events').length;
    applyRealtimeMessage(input, {
      'type': 'alert',
      'payload': {'childId': 'child-1', 'category': 'sos'},
    });
    await tester.pumpAndSettle();
    expect(api.calls('GET', '/v1/social/events'), hasLength(requestsBefore));
    applyRealtimeMessage(input, {
      'type': 'alert',
      'payload': {'childId': 'child-1', 'category': 'social_concern'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Recent sender'), findsOneWidget);
    final requests = api.calls('GET', '/v1/social/events');
    expect(requests, hasLength(requestsBefore + 1));
    expect(requests.last.query['childId'], 'child-1');
  });
}
