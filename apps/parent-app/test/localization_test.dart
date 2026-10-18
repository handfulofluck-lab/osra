import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/settings/appearance_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/locale_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  /// Drains every exception recorded by the test binding (layout overflows
  /// surface here); callers assert the list is empty.
  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  Map<String, dynamic> usagePayload(int days) => {
        'childId': 'child-1',
        'days': days,
        'totalMinutes': days * 10,
        'series': [
          for (var i = 0; i < days; i++)
            {
              'day': DateTime.utc(2026, 9, 1).add(Duration(days: i)).toIso8601String().substring(0, 10),
              'minutes': 10,
              'apps': const <Map<String, dynamic>>[],
            },
        ],
      };

  /// Routes the nine screens need, on top of the standard fixture.
  FakeApiClient arabicApi() => FakeApiClient({
        ...standardRoutes(),
        'GET /v1/reports/summary': (_) => {
              'totalAppMinutes': 300,
              'topApps': [
                {'name': 'YouTube', 'minutes': 120},
                {'name': 'TikTok', 'minutes': 90},
              ],
              'urlVisits': 42,
              'topBlockedDomains': [
                {'domain': 'tiktok.com', 'count': 12},
              ],
              'socialConcerns': 2,
              'calls': 7,
              'sms': 15,
            },
        'GET /v1/reports/usage': (req) => usagePayload(req.query['days'] as int),
        'GET /v1/reports/web': (_) => {
              'childId': 'child-1',
              'days': 7,
              'items': [
                {
                  'id': 'v1',
                  'childId': 'child-1',
                  'deviceId': 'dev-1',
                  'domain': 'tiktok.com',
                  'url': 'https://tiktok.com/page',
                  'blocked': true,
                  'category': 'social',
                  'ts': DateTime.now().toUtc().toIso8601String(),
                },
              ],
            },
      });

  /// Pumps [home] in Arabic, RTL, at 320x568 — the narrowest supported width.
  Future<void> pumpArabic(WidgetTester tester, Widget home, FakeApiClient api, {bool settle = true}) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        home,
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // Screens with a live timer (pairing countdown) cannot settle.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  void expectRtlAndNoOverflow(WidgetTester tester) {
    final scaffold = find.byType(Scaffold);
    expect(scaffold, findsWidgets);
    expect(Directionality.of(tester.element(scaffold.first)), TextDirection.rtl);
    final exceptions = drainExceptions(tester);
    expect(
      exceptions,
      isEmpty,
      reason: exceptions.map((e) => e is FlutterError ? e.toStringDeep() : '$e').join('\n'),
    );
  }

  group('Arabic + RTL at 320x568 (no overflow)', () {
    testWidgets('login', (tester) async {
      await pumpArabic(tester, const LoginScreen(), arabicApi());
      expect(find.text('تسجيل الدخول'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('dashboard', (tester) async {
      await pumpArabic(tester, const DashboardScreen(), arabicApi());
      expect(find.text('إضافة طفل'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('child detail', (tester) async {
      await pumpArabic(tester, const ChildDetailScreen(childId: 'child-1'), arabicApi());
      expect(find.text('نظرة عامة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('alerts', (tester) async {
      await pumpArabic(tester, const AlertsScreen(), arabicApi());
      expect(find.text('التنبيهات'), findsWidgets);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('rules editor', (tester) async {
      await pumpArabic(tester, const RulesEditorScreen(childId: 'child-1'), arabicApi());
      expect(find.text('وقت الشاشة'), findsWidgets);
      expect(find.text('الحد اليومي: 120 دقيقة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('reports', (tester) async {
      await pumpArabic(tester, const ReportsScreen(childId: 'child-1'), arabicApi());
      expect(find.text('التقارير'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('usage history', (tester) async {
      await pumpArabic(tester, const UsageHistoryScreen(childId: 'child-1'), arabicApi());
      expect(find.text('وقت الشاشة والويب'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('pairing QR', (tester) async {
      await pumpArabic(tester, const PairingQrScreen(childId: 'child-1'), arabicApi(), settle: false);
      expect(find.text('إقران جهاز'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
      // Dispose the 1 s countdown timer.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('appearance', (tester) async {
      await pumpArabic(tester, const AppearanceScreen(), arabicApi());
      expect(find.text('المظهر'), findsOneWidget);
      expect(find.text('اللغة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });
  });

  testWidgets('the locale override persists across a tree rebuild', (tester) async {
    final api = arabicApi();
    Widget app() => ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: Consumer(
            builder: (context, ref, _) {
              final locale = ref.watch(localeProvider);
              return localizedTestApp(
                const AppearanceScreen(),
                locale: locale ?? const Locale('en'),
                textDirection: locale?.languageCode == 'ar' ? TextDirection.rtl : null,
              );
            },
          ),
        );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('localeSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العربية').last);
    await tester.pumpAndSettle();
    expect(find.text('المظهر'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kAppLocaleKey), 'ar');

    // A rebuilt tree means a new ProviderScope/container: the only way it can
    // come back Arabic is the persisted preference.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('المظهر'), findsOneWidget);
    expect(find.text('اللغة'), findsOneWidget);
  });

  group('ARB completeness', () {
    Map<String, dynamic> readArb(String name) =>
        jsonDecode(File('lib/l10n/$name').readAsStringSync()) as Map<String, dynamic>;

    Set<String> messageKeys(Map<String, dynamic> arb) =>
        {for (final k in arb.keys) if (!k.startsWith('@')) k};

    test('every English message has a non-empty Arabic translation', () {
      final en = readArb('app_en.arb');
      final ar = readArb('app_ar.arb');
      final missing = <String>[];
      final empty = <String>[];
      for (final key in messageKeys(en)) {
        if (!ar.containsKey(key)) {
          missing.add(key);
        } else if ((ar[key] as String?)?.trim().isEmpty ?? true) {
          empty.add(key);
        }
      }
      expect(missing, isEmpty, reason: 'app_ar.arb is missing: ${missing.join(', ')}');
      expect(empty, isEmpty, reason: 'app_ar.arb has empty values: ${empty.join(', ')}');
      expect(messageKeys(ar).difference(messageKeys(en)), isEmpty,
          reason: 'app_ar.arb has keys that app_en.arb does not');
    });

    test('placeholders match between English and Arabic', () {
      final en = readArb('app_en.arb');
      final ar = readArb('app_ar.arb');
      final placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)[,}]');
      for (final key in messageKeys(en)) {
        final enNames = {
          for (final m in placeholder.allMatches(en[key] as String)) m.group(1)!,
        };
        final arNames = {
          for (final m in placeholder.allMatches((ar[key] as String?) ?? '')) m.group(1)!,
        };
        expect(arNames, enNames, reason: 'placeholder mismatch for "$key"');
      }
    });
  });
}
