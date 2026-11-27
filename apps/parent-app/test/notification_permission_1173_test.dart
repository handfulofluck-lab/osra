import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/push/notification_permission_service.dart';
import 'package:familyshield_parent/push/push_registration.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

class _FakePermissionPlatform extends NotificationPermissionPlatform {
  _FakePermissionPlatform({
    this.enabled = false,
    this.requestResult = true,
  });

  bool? enabled;
  bool? requestResult;
  int areEnabledCalls = 0;
  int requestCalls = 0;
  int openSettingsCalls = 0;
  final StreamController<String> refreshController =
      StreamController<String>.broadcast();

  @override
  Future<bool?> areNotificationsEnabled() async {
    areEnabledCalls += 1;
    return enabled;
  }

  @override
  Future<bool?> requestPermission() async {
    requestCalls += 1;
    if (requestResult != null) {
      enabled = requestResult;
    }
    return requestResult;
  }

  @override
  Future<bool> openNotificationSettings() async {
    openSettingsCalls += 1;
    return true;
  }

  @override
  Stream<String> get onTokenRefresh => refreshController.stream;

  Future<void> dispose() => refreshController.close();
}

class _SuspendingPushSource implements PushTokenSource {
  _SuspendingPushSource();

  PushPermission permission = PushPermission.granted;
  Completer<String?> tokenCompleter = Completer<String?>();
  int permissionCalls = 0;
  int tokenCalls = 0;

  @override
  Future<PushPermission> requestPermission() async {
    permissionCalls += 1;
    return permission;
  }

  @override
  Future<String?> token() {
    tokenCalls += 1;
    return tokenCompleter.future;
  }
}

class _FakePushSource implements PushTokenSource {
  _FakePushSource();

  PushPermission permission = PushPermission.granted;
  String? currentToken = 'fcm-token-parent-0123456789abcdef';
  int permissionCalls = 0;
  int tokenCalls = 0;

  @override
  Future<PushPermission> requestPermission() async {
    permissionCalls += 1;
    return permission;
  }

  @override
  Future<String?> token() async {
    tokenCalls += 1;
    return currentToken;
  }
}

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var count = 0;
    for (final p in paths) {
      final f = File(p);
      if (f.existsSync()) {
        loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
        count++;
      }
    }
    if (count > 0) await loader.load();
  }

  final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/KARIM/tools/flutter';
  await load('Roboto', [
    'test/fonts/roboto-regular.ttf',
    'test/fonts/roboto-medium.ttf',
    'test/fonts/roboto-bold.ttf',
  ]);
  await load('NotoNaskhArabic', [
    '$sdk/engine/src/flutter/txt/third_party/fonts/NotoNaskhArabic-Regular.ttf',
  ]);
  await load('MaterialIcons', [
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFonts();
  });

  const frameBoundaryKey = ValueKey('alertsOffFrameRepaintBoundary');

  List<Object> drainExceptions(WidgetTester tester) {
    final out = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return out;
      out.add(e);
    }
  }

  Future<void> settleAsync([int ticks = 8]) async {
    for (var i = 0; i < ticks; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> flushWidgetAsync(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Map<String, FakeRoute> pushRoutes() => {
        ...standardRoutes(),
        'POST /v1/me/push-token': (req) => {
              'id': 'push-row-1',
              'platform': req.body['platform'] ?? 'android',
              'registeredAt': '2026-11-26T16:00:00Z',
            },
        'DELETE /v1/me/push-token': (_) => const {'removed': 1},
        'GET /v1/reports/wellbeing/child-1': (_) => {
              'childId': 'child-1',
              'score': 88,
              'components': {'screenTime': 90, 'social': 86, 'safety': 88},
            },
        'GET /v1/reports/wellbeing/child-2': (_) => {
              'childId': 'child-2',
              'score': 92,
              'components': {'screenTime': 92, 'social': 92, 'safety': 92},
            },
      };

  Widget buildDashboardApp({
    required FakeApiClient api,
    required _FakePermissionPlatform platform,
    required _FakePushSource pushSource,
    Locale locale = const Locale('en'),
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(390, 844),
    double textScale = 1.0,
  }) {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Consumer(
            builder: (context, ref, _) {
              ref.watch(notificationLifecycleSyncProvider);
              return const DashboardScreen();
            },
          ),
        ),
        GoRoute(
          path: '/login',
          builder: (_, __) => const Scaffold(body: Text('Login')),
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        notificationPermissionPlatformProvider.overrideWithValue(platform),
        pushTokenSourceProvider.overrideWithValue(pushSource),
        placemarkLookupProvider.overrideWithValue(
          (lat, lng, loc) async => [
            Placemark(
              subLocality: loc.languageCode == 'ar' ? 'البرشاء' : 'Al Barsha',
              locality: loc.languageCode == 'ar' ? 'دبي' : 'Dubai',
            ),
          ],
        ),
      ],
      child: RepaintBoundary(
        key: frameBoundaryKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          locale: locale,
          theme: AppTheme.light.copyWith(
            textTheme: AppTheme.light.textTheme.apply(
              fontFamily: 'Roboto',
              fontFamilyFallback: const ['NotoNaskhArabic'],
            ),
          ),
          darkTheme: AppTheme.dark.copyWith(
            textTheme: AppTheme.dark.textTheme.apply(
              fontFamily: 'Roboto',
              fontFamilyFallback: const ['NotoNaskhArabic'],
            ),
          ),
          themeMode: themeMode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Directionality(
              textDirection: locale.languageCode == 'ar'
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: child!,
            ),
          ),
        ),
      ),
    );
  }

  group('#1173 permission timing & push-token registration lifecycle', () {
    /// Mutant: ask OS permission on cold start or inside `AuthNotifier.bootstrap()`
    /// while `onboarding.inProgress` is true, and `platform.requestCalls` fires
    /// before sign-in or before family setup finishes.
    test('never prompts on cold start or mid-onboarding; prompts once right after setup completes and posts token', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'welcome',
      });
      final api = FakeApiClient(pushRoutes());
      final platform = _FakePermissionPlatform(enabled: false, requestResult: true);
      final pushSource = _FakePushSource();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          notificationPermissionPlatformProvider.overrideWithValue(platform),
          pushTokenSourceProvider.overrideWithValue(pushSource),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await platform.dispose();
      });

      container.read(notificationLifecycleSyncProvider);
      await settleAsync(12);

      // 1. Cold start unauthenticated -> 0 prompts, 0 token POSTs.
      expect(platform.requestCalls, 0);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);

      // 2. Sign in while onboarding is still in progress (add_child step) -> still 0 prompts!
      await container
          .read(onboardingProvider.notifier)
          .signedIn();
      await container
          .read(authProvider.notifier)
          .login('qa@osratech.com', 'good-password');
      await settleAsync(12);
      expect(container.read(authProvider).isAuthenticated, isTrue);
      expect(container.read(onboardingProvider).inProgress, isTrue);
      expect(platform.requestCalls, 0);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);

      // 3. Family setup finishes -> prompts once and immediately POSTs push token!
      await container.read(onboardingProvider.notifier).completeSetup();
      await settleAsync(16);
      expect(platform.requestCalls, 1);
      final sent = api.calls('POST', '/v1/me/push-token');
      expect(sent, hasLength(1));
      expect(sent.single.body['token'], 'fcm-token-parent-0123456789abcdef');
      expect(
        container.read(notificationPermissionControllerProvider).showAlertsOffBanner,
        isFalse,
      );
    });

    /// Mutant: clear `_registeredToken` only on successful `_api.remove` in `unregister()`,
    /// and an offline sign-out leaves `_registeredToken` set so a second parent signing in
    /// on the same app run skips `POST /v1/me/push-token`.
    test('offline logout still clears _registeredToken so a subsequent sign-in re-registers', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final api = FakeApiClient({
        ...pushRoutes(),
        'DELETE /v1/me/push-token': (_) =>
            const FakeHttpError(503, {'error': 'offline'}),
      });
      final platform = _FakePermissionPlatform(enabled: true, requestResult: true);
      final pushSource = _FakePushSource();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          notificationPermissionPlatformProvider.overrideWithValue(platform),
          pushTokenSourceProvider.overrideWithValue(pushSource),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await platform.dispose();
      });

      container.read(notificationLifecycleSyncProvider);
      await container.read(authProvider.notifier).login('p1@osratech.com', 'good-password');
      await settleAsync(16);
      expect(api.calls('POST', '/v1/me/push-token'), hasLength(1));

      await container.read(authProvider.notifier).logout();
      await settleAsync(12);
      expect(api.calls('DELETE', '/v1/me/push-token'), hasLength(1));

      // Second parent signs in during the same app run with the same device FCM token.
      await container.read(authProvider.notifier).login('p2@osratech.com', 'good-password');
      await settleAsync(16);
      expect(api.calls('POST', '/v1/me/push-token'), hasLength(2));
    });

    /// Mutant A: check only `auth.isAuthenticated` on `onTokenRefresh` -> posts token mid-onboarding.
    /// Mutant B: skip `areNotificationsEnabled() == true` check on refresh or `ensureRegistered(refreshedToken:)`
    /// -> posts device push identifier while OS notifications are disabled, or prompts unexpectedly.
    test('token refresh respects onboarding readiness and non-prompting OS notification setting, then posts once eligible', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'welcome',
      });
      final api = FakeApiClient(pushRoutes());
      final platform = _FakePermissionPlatform(enabled: false, requestResult: false);
      final pushSource = _FakePushSource();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          notificationPermissionPlatformProvider.overrideWithValue(platform),
          pushTokenSourceProvider.overrideWithValue(pushSource),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await platform.dispose();
      });

      container.read(notificationLifecycleSyncProvider);
      await container.read(onboardingProvider.notifier).signedIn();
      await container.read(authProvider.notifier).login('qa@osratech.com', 'good-password');
      await settleAsync(12);
      expect(container.read(authProvider).isAuthenticated, isTrue);
      expect(container.read(onboardingProvider).inProgress, isTrue);

      // 1. Token refresh during incomplete onboarding (even if OS notifications were enabled) -> 0 POSTs, 0 prompts.
      platform.enabled = true;
      platform.refreshController.add('fcm-token-mid-onboarding-0001');
      await settleAsync(12);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);
      expect(platform.requestCalls, 0);

      // 2. Complete onboarding while OS notifications are disabled -> prompt runs once (denied), 0 POSTs.
      platform.enabled = false;
      await container.read(onboardingProvider.notifier).completeSetup();
      await settleAsync(16);
      expect(platform.requestCalls, 1);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);

      // 3. Token refresh while OS notifications are disabled -> non-prompting check blocks POST (0 extra prompts, 0 POSTs).
      final enabledChecksBefore = platform.areEnabledCalls;
      platform.refreshController.add('fcm-token-disabled-os-0002');
      await settleAsync(12);
      expect(platform.areEnabledCalls, greaterThan(enabledChecksBefore));
      expect(platform.requestCalls, 1);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);

      // Direct refreshed-token call on AuthNotifier/PushRegistration also enforces non-prompting permission.
      final directBlocked = await container
          .read(authProvider.notifier)
          .syncPushRegistration(refreshedToken: 'fcm-token-direct-disabled-0003');
      expect(directBlocked, PushRegistrationOutcome.denied);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);

      // 4. Parent enables notifications in OS Settings -> subsequent token refresh posts cleanly with 0 extra prompts.
      platform.enabled = true;
      await container.read(notificationPermissionControllerProvider.notifier).onAppResumed();
      await settleAsync(14);
      expect(api.calls('POST', '/v1/me/push-token'), hasLength(1));

      platform.refreshController.add('fcm-token-eligible-refresh-0004');
      await settleAsync(14);
      final posts = api.calls('POST', '/v1/me/push-token');
      expect(posts, hasLength(2));
      expect(posts.last.body['token'], 'fcm-token-eligible-refresh-0004');
      expect(platform.requestCalls, 1);
    });

    /// Mutant A: fail to bump `_sessionEpoch` on `unregister()` -> suspended `token()` resolving after
    /// `logout()` still POSTs `/v1/me/push-token` or sets `_registeredToken` on a departed session.
    /// Mutant B: fail to await in-flight `POST /v1/me/push-token` inside `unregister()` before
    /// `/v1/auth/logout` -> `POST` lands on the server without `DELETE` (or `DELETE` hits 401 after logout).
    test('logout during in-flight registration never leaves a token attached to a departed session', () async {
      // Subcase A: logout while PushTokenSource.token() is suspended.
      FlutterSecureStorage.setMockInitialValues({'refresh': 'rt-1'});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final apiA = FakeApiClient(pushRoutes());
      final platformA = _FakePermissionPlatform(enabled: true, requestResult: true);
      final suspendingSource = _SuspendingPushSource();
      final containerA = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(apiA),
          notificationPermissionPlatformProvider.overrideWithValue(platformA),
          pushTokenSourceProvider.overrideWithValue(suspendingSource),
        ],
      );
      addTearDown(() async {
        containerA.dispose();
        await platformA.dispose();
      });

      containerA.read(notificationLifecycleSyncProvider);
      await containerA.read(authProvider.notifier).login('p1@osratech.com', 'good-password');
      await settleAsync(16);
      expect(suspendingSource.tokenCalls, 1);
      expect(apiA.calls('POST', '/v1/me/push-token'), isEmpty);

      // Logout finishes while token() is still pending, then token() resolves late.
      await containerA.read(authProvider.notifier).logout();
      suspendingSource.tokenCompleter.complete('fcm-token-late-after-logout');
      await settleAsync(12);
      expect(apiA.calls('POST', '/v1/me/push-token'), isEmpty);

      // Subcase B: logout while POST /v1/me/push-token is in flight on the wire.
      FlutterSecureStorage.setMockInitialValues({'refresh': 'rt-2'});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final serverActiveTokens = <String>{};
      var serverSessionRevoked = false;
      final postGate = Completer<void>();

      final apiB = FakeApiClient({
        ...pushRoutes(),
        'POST /v1/auth/login': (_) => {
              'token': 'jwt-b',
              'refreshToken': 'rt-2',
            },
        'POST /v1/auth/logout': (_) {
          serverSessionRevoked = true;
          return const {'ok': true};
        },
        'POST /v1/me/push-token': (req) => FakeDeferred(
              postGate.future.then((_) {
                final tok = req.body['token'] as String;
                if (!serverSessionRevoked) {
                  serverActiveTokens.add(tok);
                }
                return {
                  'id': 'push-row-b',
                  'platform': req.body['platform'] ?? 'android',
                  'registeredAt': '2026-11-27T00:00:00Z',
                };
              }),
            ),
        'DELETE /v1/me/push-token': (req) {
          if (serverSessionRevoked) {
            return const FakeHttpError(401, {'error': 'session_revoked'});
          }
          final tok = req.body['token'] as String;
          final removed = serverActiveTokens.remove(tok) ? 1 : 0;
          return {'removed': removed};
        },
      });
      final platformB = _FakePermissionPlatform(enabled: true, requestResult: true);
      final pushSourceB = _FakePushSource();
      final containerB = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(apiB),
          notificationPermissionPlatformProvider.overrideWithValue(platformB),
          pushTokenSourceProvider.overrideWithValue(pushSourceB),
        ],
      );
      addTearDown(() async {
        containerB.dispose();
        await platformB.dispose();
      });

      containerB.read(notificationLifecycleSyncProvider);
      await containerB.read(authProvider.notifier).login('p1@osratech.com', 'good-password');
      await settleAsync(16);
      expect(apiB.calls('POST', '/v1/me/push-token'), hasLength(1));

      // Start logout while POST /v1/me/push-token is suspended on the wire, then release POST.
      final logoutFuture = containerB.read(authProvider.notifier).logout();
      await settleAsync(4);
      postGate.complete();
      await logoutFuture;
      await settleAsync(8);

      expect(apiB.calls('DELETE', '/v1/me/push-token'), hasLength(1));
      expect(apiB.calls('POST', '/v1/auth/logout'), hasLength(1));
      expect(serverActiveTokens, isEmpty);
    });

    /// Mutant A: overwrite `_registeredToken` on rotation without retaining prior session tokens ->
    /// after a completed rotation (`tok1` -> `tok2`), `logout()` deletes only `tok2` and leaves `tok1` active.
    /// Mutant B: allow an in-flight rotation (`tok2`) resuming after `_sessionEpoch` bumps to clear
    /// `_registeredToken` (`tok1`) before `unregister()` snapshots cleanup -> `logout()` deletes only `tok2`
    /// and leaves `tok1` active on the server.
    test('sign-out after completed rotation or during in-flight rotation removes both initial and rotated registrations', () async {
      // Case 1: sign-in -> initial registration -> completed token rotation -> sign-out
      FlutterSecureStorage.setMockInitialValues({'refresh': 'rt-rot-1'});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final activeOnServer1 = <String>{};
      var revoked1 = false;

      final api1 = FakeApiClient({
        ...pushRoutes(),
        'POST /v1/auth/login': (_) => {'token': 'jwt-token', 'refreshToken': 'rt-1'},
        'POST /v1/auth/logout': (_) {
          revoked1 = true;
          return const {'ok': true};
        },
        'POST /v1/me/push-token': (req) {
          if (revoked1) return const FakeHttpError(401, {'error': 'session_revoked'});
          final tok = req.body['token'] as String;
          activeOnServer1.add(tok);
          return {'id': 'row-${activeOnServer1.length}', 'platform': 'android', 'registeredAt': '2026-11-27T00:00:00Z'};
        },
        'DELETE /v1/me/push-token': (req) {
          if (revoked1) return const FakeHttpError(401, {'error': 'session_revoked'});
          final tok = req.body['token'] as String;
          return {'removed': activeOnServer1.remove(tok) ? 1 : 0};
        },
      });
      final platform1 = _FakePermissionPlatform(enabled: true, requestResult: true);
      final source1 = _FakePushSource()..currentToken = 'aaa111';
      final container1 = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api1),
          notificationPermissionPlatformProvider.overrideWithValue(platform1),
          pushTokenSourceProvider.overrideWithValue(source1),
        ],
      );
      addTearDown(() async {
        container1.dispose();
        await platform1.dispose();
      });

      container1.read(notificationLifecycleSyncProvider);
      await container1.read(authProvider.notifier).login('p1@osratech.com', 'good-password');
      await settleAsync(16);
      expect(activeOnServer1, {'aaa111'});

      platform1.refreshController.add('bbb222');
      await settleAsync(16);
      expect(activeOnServer1, {'aaa111', 'bbb222'});

      await container1.read(authProvider.notifier).logout();
      await settleAsync(10);
      expect(activeOnServer1, isEmpty, reason: 'completed rotation must not leave initial token registered after sign-out');

      // Case 2: sign-in -> initial registration -> rotation POST in-flight during sign-out
      FlutterSecureStorage.setMockInitialValues({'refresh': 'rt-2'});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final activeOnServer2 = <String>{};
      var revoked2 = false;
      final rotationGate = Completer<void>();

      final api2 = FakeApiClient({
        ...pushRoutes(),
        'POST /v1/auth/login': (_) => {'token': 'jwt-token', 'refreshToken': 'rt-2'},
        'POST /v1/auth/logout': (_) {
          revoked2 = true;
          return const {'ok': true};
        },
        'POST /v1/me/push-token': (req) {
          final tok = req.body['token'] as String;
          if (tok == 'ccc333') {
            return FakeDeferred(
              rotationGate.future.then((_) {
                if (!revoked2) activeOnServer2.add(tok);
                return {'id': 'row-2', 'platform': 'android', 'registeredAt': '2026-11-27T00:00:00Z'};
              }),
            );
          }
          if (revoked2) return const FakeHttpError(401, {'error': 'session_revoked'});
          activeOnServer2.add(tok);
          return {'id': 'row-1', 'platform': 'android', 'registeredAt': '2026-11-27T00:00:00Z'};
        },
        'DELETE /v1/me/push-token': (req) {
          if (revoked2) return const FakeHttpError(401, {'error': 'session_revoked'});
          final tok = req.body['token'] as String;
          return {'removed': activeOnServer2.remove(tok) ? 1 : 0};
        },
      });
      final platform2 = _FakePermissionPlatform(enabled: true, requestResult: true);
      final source2 = _FakePushSource()..currentToken = 'aaa111';
      final container2 = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api2),
          notificationPermissionPlatformProvider.overrideWithValue(platform2),
          pushTokenSourceProvider.overrideWithValue(source2),
        ],
      );
      addTearDown(() async {
        container2.dispose();
        await platform2.dispose();
      });

      container2.read(notificationLifecycleSyncProvider);
      await container2.read(authProvider.notifier).login('p1@osratech.com', 'good-password');
      await settleAsync(16);
      expect(activeOnServer2, {'aaa111'});

      // Start rotation to tok-2 (suspended on wire), then trigger logout while rotation POST is in flight.
      platform2.refreshController.add('ccc333');
      await settleAsync(10);
      expect(api2.calls('POST', '/v1/me/push-token'), hasLength(2));

      final logoutFut = container2.read(authProvider.notifier).logout();
      await settleAsync(4);
      rotationGate.complete();
      await logoutFut;
      await settleAsync(10);

      final deletedTokens = api2.calls('DELETE', '/v1/me/push-token').map((r) => r.body['token']).toSet();
      expect(deletedTokens, {'aaa111', 'ccc333'});
      expect(activeOnServer2, isEmpty, reason: 'in-flight rotation during sign-out must remove both deliveries');
    });

    /// Mutant: skip `syncPushRegistration()` after `requestPermission()` grants
    /// on sign-in to an existing account, and `POST /v1/me/push-token` stays empty.
    test('sign-in to an existing account prompts once immediately, posts token, and does not re-prompt', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final api = FakeApiClient(pushRoutes());
      final platform = _FakePermissionPlatform(enabled: false, requestResult: true);
      final pushSource = _FakePushSource();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          notificationPermissionPlatformProvider.overrideWithValue(platform),
          pushTokenSourceProvider.overrideWithValue(pushSource),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await platform.dispose();
      });

      container.read(notificationLifecycleSyncProvider);
      await settleAsync(10);
      expect(platform.requestCalls, 0);

      await container
          .read(authProvider.notifier)
          .login('qa@osratech.com', 'good-password');
      await settleAsync(16);

      expect(platform.requestCalls, 1);
      expect(api.calls('POST', '/v1/me/push-token'), hasLength(1));

      // Subsequent resume does not re-prompt or duplicate POST when token is unchanged.
      await container
          .read(notificationPermissionControllerProvider.notifier)
          .onAppResumed();
      await settleAsync(10);
      expect(platform.requestCalls, 1);
      expect(api.calls('POST', '/v1/me/push-token'), hasLength(1));

      // Token rotation forwards the new token immediately.
      platform.refreshController.add('fcm-token-rotated-9999999999999999');
      await settleAsync(12);
      final allCalls = api.calls('POST', '/v1/me/push-token');
      expect(allCalls, hasLength(2));
      expect(allCalls.last.body['token'], 'fcm-token-rotated-9999999999999999');
    });

    /// Mutant: omit `onAppResumed` re-check or omit `syncPushRegistration` on resume,
    /// and enabling notifications in system Settings leaves the Home banner stuck
    /// or fails to POST `/v1/me/push-token`.
    testWidgets('denied permission shows Home banner, Turn on alerts opens Settings, and resume clears banner + posts token', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final api = FakeApiClient(pushRoutes());
      final platform =
          _FakePermissionPlatform(enabled: false, requestResult: false);
      final pushSource = _FakePushSource();
      addTearDown(platform.dispose);

      await tester.pumpWidget(
        buildDashboardApp(
          api: api,
          platform: platform,
          pushSource: pushSource,
        ),
      );
      await flushWidgetAsync(tester);
      await tester.pumpAndSettle();

      // Prompt ran once, parent denied -> banner is visible, 0 push tokens posted.
      expect(platform.requestCalls, 1);
      expect(api.calls('POST', '/v1/me/push-token'), isEmpty);
      expect(find.byKey(const ValueKey('alertsOffBanner')), findsOneWidget);
      expect(
        find.text("Alerts are off. You won't hear about urgent messages."),
        findsOneWidget,
      );

      // Tap "Turn on alerts" -> opens OS notification settings.
      await tester.tap(find.byKey(const ValueKey('alertsOffTurnOnButton')));
      await tester.pump();
      expect(platform.openSettingsCalls, 1);

      // Parent switches notifications ON in Settings and returns to app (resumed).
      platform.enabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flushWidgetAsync(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('alertsOffBanner')), findsNothing);
      final posted = api.calls('POST', '/v1/me/push-token');
      expect(posted, hasLength(1));
      expect(posted.single.body['token'], 'fcm-token-parent-0123456789abcdef');

      // Parent later turns notifications OFF in Settings -> banner reappears on resume.
      platform.enabled = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flushWidgetAsync(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alertsOffBanner')), findsOneWidget);
    });
  });

  group('#1173 Home banner EN/AR light/dark 390px + 320px at 200% layout & Arabic Bureau matrix', () {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
        for (final (size, scale) in const [
          (Size(390, 844), 1.0),
          (Size(320, 568), 2.0),
        ]) {
          final label =
              '${locale.languageCode} | ${mode.name} | ${size.width.toInt()}x${size.height.toInt()} | ${scale}x';

          /// Mutant: use fixed non-wrapping row or unapproved Arabic translation
          /// and `320px at 2.0x` overflows or fails `7193252181` verbatim check.
          testWidgets('renders AlertsOffBanner cleanly with >=48dp CTA and zero overflow [$label]', (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });

            FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
            SharedPreferences.setMockInitialValues({
              kOnboardingCompleteKey: true,
              kPushPermissionPromptedKey: true,
            });
            final baseFamily = familyMeTwoChildren(
              alexName: locale.languageCode == 'ar' ? 'محمد مصطفى' : 'Alex',
            );
            final api = FakeApiClient({
              ...pushRoutes(),
              'GET /v1/family/me': (_) => {
                    ...baseFamily,
                    'children': [
                      (baseFamily['children'] as List).first,
                      {
                        'id': 'child-2',
                        'familyId': 'fam-1',
                        'displayName':
                            locale.languageCode == 'ar' ? 'سارة' : 'Sam',
                        'birthYear': 2016,
                        'screenTimeTodayMinutes': 10,
                      },
                    ],
                  },
            });
            final platform =
                _FakePermissionPlatform(enabled: false, requestResult: false);
            final pushSource = _FakePushSource();
            addTearDown(platform.dispose);

            await tester.pumpWidget(
              buildDashboardApp(
                api: api,
                platform: platform,
                pushSource: pushSource,
                locale: locale,
                themeMode: mode,
                size: size,
                textScale: scale,
              ),
            );
            await flushWidgetAsync(tester);
            await tester.pumpAndSettle();

            final exceptions = drainExceptions(tester);
            expect(exceptions, isEmpty, reason: 'Overflow in $label: $exceptions');
            expect(find.byKey(const ValueKey('alertsOffBanner')), findsOneWidget);

            final btnRect = tester.getRect(
              find.byKey(const ValueKey('alertsOffTurnOnButton')),
            );
            expect(btnRect.height, greaterThanOrEqualTo(48.0));

            if (locale.languageCode == 'ar') {
              final ctx = tester.element(
                find.byKey(const ValueKey('alertsOffBanner')),
              );
              expect(Directionality.of(ctx), TextDirection.rtl);
              expect(
                find.text('التنبيهات متوقفة، فلن يصلك أي تنبيه عاجل.'),
                findsOneWidget,
              );
              expect(find.text('تفعيل التنبيهات'), findsOneWidget);
            } else {
              expect(
                find.text("Alerts are off. You won't hear about urgent messages."),
                findsOneWidget,
              );
              expect(find.text('Turn on alerts'), findsOneWidget);
            }

            final framesDir = Platform.environment['OSRA_1173_FRAMES_DIR'];
            if (framesDir != null && framesDir.isNotEmpty) {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(frameBoundaryKey),
              );
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 2.0);
                final byteData =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                image.dispose();
                if (byteData != null) {
                  final outDir = Directory(framesDir);
                  if (!outDir.existsSync()) outDir.createSync(recursive: true);
                  final scalePct = (scale * 100).round();
                  final name =
                      'alerts_off_1173_${locale.languageCode}_${mode.name}_${size.width.toInt()}_$scalePct.png';
                  File('${outDir.path}/$name')
                      .writeAsBytesSync(byteData.buffer.asUint8List());
                }
              });
            }
          });
        }
      }
    }
  });
}