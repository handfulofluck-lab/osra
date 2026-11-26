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