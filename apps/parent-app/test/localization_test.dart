import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/consent_screen.dart';
import 'package:familyshield_parent/features/content/search_safety_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/settings/digest_prefs_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/features/settings/appearance_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/locale_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';
import 'package:familyshield_parent/features/family/family_screen.dart';

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

    testWidgets('consent status', (tester) async {
      await pumpArabic(tester, const ConsentScreen(childId: 'child-1'), arabicApi());
      expect(find.text('موافقة الوالدين'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('consent withdrawal', (tester) async {
      await pumpArabic(
        tester,
        const ConsentRevokeScreen(childId: 'child-1', childName: 'أليكس'),
        arabicApi(),
      );
      expect(find.text('سحب الموافقة؟'), findsOneWidget);
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
      expect(find.text('الإجمالي: 300 دقيقة · المتوسط: 43 دقيقة يوميًا'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('family members', (tester) async {
      // 3.1 remainder / #419: the family screen was the last untranslated one, so these two assertions are
      // the first time its Arabic has been rendered at all.
      await pumpArabic(tester, const FamilyScreen(), arabicApi());
      expect(find.text('أفراد العائلة'), findsOneWidget);
      expect(find.text('الدعوات المعلّقة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('family map', (tester) async {
      // #419 second half: the map screen was the last parent-app screen written in English. The
      // title is the app bar's, so this row fails if the screen falls back to its English literal.
      await pumpArabic(tester, const FamilyMapScreen(), arabicApi());
      expect(find.text('خريطة العائلة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('usage history', (tester) async {
      await pumpArabic(tester, const UsageHistoryScreen(childId: 'child-1'), arabicApi());
      expect(find.text('وقت الشاشة والويب'), findsOneWidget);
      expect(find.text('7 أيام'), findsOneWidget);
      expect(find.text('14 يومًا'), findsOneWidget);
      expect(find.text('30 يومًا'), findsOneWidget);
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

    test('no key is defined twice in either file', () {
      // jsonDecode keeps the LAST duplicate and says nothing, so the two tests above cannot see a
      // repeated key — they read the file through the parser that hides it. Two keys shipped twice
      // (#423): one identical (`familyLoadFailed`), one with two different sentences under one name
      // (`mfaResetWitnessRequired`), where the shadowed definition was the correct failure message.
      final definition = RegExp(r'^  "([^"]+)":', multiLine: true);
      for (final name in ['app_en.arb', 'app_ar.arb']) {
        final seen = <String, int>{};
        for (final m in definition.allMatches(File('lib/l10n/$name').readAsStringSync())) {
          seen.update(m.group(1)!, (n) => n + 1, ifAbsent: () => 1);
        }
        final twice = [for (final e in seen.entries) if (e.value > 1) e.key];
        expect(twice, isEmpty, reason: '$name defines these keys more than once: ${twice.join(', ')}');
      }
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

    test('the four alert-title keys are present and non-empty in both locales', () {
      final en = readArb('app_en.arb');
      final ar = readArb('app_ar.arb');
      const titles = [
        'alertTitleSos',
        'alertTitleBlockedSite',
        'alertTitleDailyLimit',
        'alertTitleGeneric',
      ];
      for (final key in titles) {
        expect(en.containsKey(key), isTrue, reason: 'app_en.arb is missing $key');
        expect(ar.containsKey(key), isTrue, reason: 'app_ar.arb is missing $key');
        expect((en[key] as String).trim(), isNotEmpty, reason: 'app_en.arb $key is empty');
        expect((ar[key] as String).trim(), isNotEmpty, reason: 'app_ar.arb $key is empty');
      }
    });
  });

  /// The fake HTTP layer resolves on a microtask after the first frame, so a provider-backed screen
  /// needs a few pumps before its data is on screen. `coach_test.dart` has the same helper privately.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The alerts feed with every category the server can send, so the maintainer
  /// reviews the new Arabic titles in one render instead of taking the mapping's
  /// word for it. Each title is asserted as the feed is scrolled, and the frame
  /// is the same 320×568 RTL one as the other screens.
  group('Alert titles, all 13 server categories (Arabic, 320×568)', () {
    FakeApiClient allCategoriesApi() {
      final now = DateTime.now();
      return FakeApiClient({
        ...standardRoutes(
          // Newest first in the feed, so the scroll below walks
          // [serverAlertCategories] in order. All on one day, so the feed groups
          // them into a single column and every tile is laid out.
          alerts: [
            for (var i = 0; i < serverAlertCategories.length; i++)
              alertJson(
                'all-$i',
                serverAlertCategories[i] == 'sos' ? 'critical' : 'warning',
                serverAlertCategories[i],
                'SERVER TITLE ${serverAlertCategories[i]}',
                now.subtract(Duration(minutes: 5 * i)),
              ),
          ],
          unacked: serverAlertCategories.length,
        ),
      });
    }

    testWidgets('every category renders its own Arabic title and label', (tester) async {
      await pumpArabic(tester, const AlertsScreen(), allCategoriesApi());
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final ar = await AppLocalizations.delegate.load(const Locale('ar'));
      var inFrame = 0;
      for (final category in serverAlertCategories) {
        final title = ar.alertTitleFor(category, 'SERVER TITLE $category', isEnglish: false);
        expect(title, isNot(ar.alertTitleGeneric), reason: '"$category" fell through to the generic title');
        // The line under the title is the short label, through the same mapping
        // as the dialog -- render 03's finding was these 11 raw keys.
        final label = ar.alertCategory(category);
        expect(label, isNot(category), reason: '"$category" still renders the raw key');
        expect(
          find.textContaining(RegExp('^${RegExp.escape(label)} · ')),
          findsWidgets,
          reason: '"$category" shows no "$label" label under its title',
        );
        // Every tile is laid out in the feed's single day column, so the finder
        // sees all 13; a frame of 568 px holds only the first five, hence the
        // scroll before the geometry check. That is what makes this the render
        // the maintainer reviews: each title is actually on screen.
        final finder = find.text(title);
        expect(finder, findsOneWidget, reason: '"$category" is missing from the Arabic feed');
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final rect = tester.getRect(finder);
        expect(rect.top, greaterThanOrEqualTo(0), reason: '"$category" scrolled above the frame');
        expect(rect.bottom, lessThanOrEqualTo(568), reason: '"$category" is not inside the 320x568 frame');
        inFrame++;
      }
      expect(inFrame, serverAlertCategories.length);
      // The server's English title is never what an Arabic parent reads.
      expect(find.textContaining('SERVER TITLE'), findsNothing);
      expectRtlAndNoOverflow(tester);
    });
  });

  /// Search safety was the last screen with hardcoded English (#275). This holds its Arabic form: RTL,
  /// no overflow at 320 px, and the two strings a parent actually reads first.
  group('Search safety in Arabic (#275)', () {
    FakeApiClient searchApi() => FakeApiClient({
          ...standardRoutes(),
          'GET /v1/content/searches': (_) => {
                'items': [
                  {
                    'id': 's-1',
                    'engine': 'google',
                    'query': 'كيف أشتري فيب',
                    'severity': 'warning',
                    'concernTypes': ['substance_use'],
                    'createdAt': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
                  },
                ],
              },
        });

    testWidgets('renders the flagged query in Arabic, RTL, no overflow', (tester) async {
      await pumpArabic(tester, const SearchSafetyScreen(childId: 'child-1'), searchApi());
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.text('أمان البحث'), findsOneWidget);
      expect(find.text('كيف أشتري فيب'), findsOneWidget);
      // The severity chip is translated rather than an English enum in Latin capitals.
      expect(find.text('تحذير'), findsOneWidget);
      // The engine name stays a brand, but the relative time is translated.
      expect(find.text('Google · قبل ساعتين'), findsOneWidget);
      expect(find.text('عرض تفاصيل الخزنة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('the empty state is translated too', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/content/searches': (_) => {'items': []},
      });
      await pumpArabic(tester, const SearchSafetyScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.text('لم يتم رصد أي عمليات بحث تستدعي الإبلاغ عنها'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });
  });

  /// Digest preferences was the next screen still written in English (#277).
  group('Digest preferences in Arabic (#277)', () {
    FakeApiClient digestApi() => FakeApiClient({
          ...standardRoutes(),
          'GET /v1/digests/prefs': (_) => {
                'dailyEmail': true,
                'weeklyEmail': false,
                'pushEnabled': true,
                'emails': ['parent@example.com'],
              },
          'GET /v1/family/me': (_) => {
                'family': {'id': 'fam-1', 'name': 'Demo Family', 'timezone': 'Asia/Dubai', 'timezoneSource': 'parent'},
              },
        });

    testWidgets('renders the switches and labels in Arabic, RTL, no overflow', (tester) async {
      await pumpArabic(tester, const DigestPrefsScreen(), digestApi());
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.text('تفضيلات الملخّص'), findsOneWidget);
      expect(find.text('ملخّص بريدي يومي'), findsOneWidget);
      expect(find.text('الإشعارات الفورية'), findsOneWidget);
      // The buttons sit below the fold at 320x568 and a ListView builds lazily, so they are reached by
      // scrolling -- an assertion that fails without it is testing the viewport, not the copy.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('حفظ التفضيلات'), findsOneWidget);
      // The send hour and timezone are separate fields, not one run-on line.
      expect(find.text('ساعة الإرسال'), findsOneWidget);
      expect(find.text('18:00'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('a pending digest recipient says the confirmation was sent (roadmap 2.7)', (tester) async {
      // Roadmap 2.7 (osra-security#2): the pending state needs Arabic copy too, and the row must not
      // overflow at 320 px with an email address in it.
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/digests/prefs': (_) => {
              'dailyEmail': true,
              'weeklyEmail': false,
              'pushEnabled': true,
              'emails': ['parent@example.com', 'grandma@example.com'],
              'recipients': [
                {'email': 'parent@example.com', 'status': 'confirmed'},
                {'email': 'grandma@example.com', 'status': 'pending'},
              ],
            },
        'GET /v1/family/me': (_) => {
              'family': {'id': 'fam-1', 'name': 'Demo Family', 'timezone': 'Asia/Dubai', 'timezoneSource': 'parent'},
            },
      });
      await pumpArabic(tester, const DigestPrefsScreen(), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      // The rows sit under the switches and the email field, and a ListView builds lazily at 320x568.
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('تم إرسال رابط التأكيد — لن يستلم هذا العنوان أي ملخّص قبل التأكيد'), findsOneWidget);
      expect(find.byKey(const ValueKey('digestRecipient-grandma@example.com')), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('a limited Arabic recipient says nothing was sent (#354 review)', (tester) async {
      // The family is at the confirmation cap, so this save mailed nothing. The Arabic row has to say
      // that, not repeat the "confirmation sent" line. Mutant: drop the `isLimited` branch.
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/digests/prefs': (_) => {
              'dailyEmail': true,
              'weeklyEmail': false,
              'pushEnabled': true,
              'emails': ['grandma@example.com'],
              'recipients': [
                {'email': 'grandma@example.com', 'status': 'pending', 'limited': true},
              ],
            },
        'GET /v1/family/me': (_) => {
              'family': {'id': 'fam-1', 'name': 'Demo Family', 'timezone': 'Asia/Dubai', 'timezoneSource': 'parent'},
            },
      });
      await pumpArabic(tester, const DigestPrefsScreen(), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(
        find.text('لم يُرسَل بعد: هناك تأكيدات كثيرة بانتظار الردّ. حاول مرة أخرى غدًا.'),
        findsOneWidget,
      );
      expect(find.textContaining('تم إرسال رابط التأكيد'), findsNothing);
      expectRtlAndNoOverflow(tester);
    });
  });

  /// Pure copy checks for the native-speaker review of the Arabic screen
  /// strings: the changed values, the plural period selectors, and the
  /// alert-title mapping that never falls back to the server's English.
  group('Arabic copy (review of #330)', () {
    Future<AppLocalizations> arabic() => AppLocalizations.delegate.load(const Locale('ar'));

    test('changed values read as the native reviewer approved', () async {
      final ar = await arabic();
      expect(ar.serverLabel, 'الخادم (السيرفر)');
      expect(ar.totalAverage(300, 43), 'الإجمالي: 300 دقيقة · المتوسط: 43 دقيقة يوميًا');
      expect(ar.digestPrefsPushBody, 'إرسال التنبيهات الحرجة كإشعارات فورية');
    });

    test('the screen-time value reads used-then-limit', () async {
      final ar = await arabic();
      expect(ar.screenTimeValue(120, 180), '120 من 180 دقيقة');
    });

    test('the retention explanation is split into paragraphs', () async {
      final ar = await arabic();
      expect(ar.consentRevokeDataRetention, contains('\n\n'));
    });

    test('the consent warning names the child instead of a dangling لـ', () async {
      final ar = await arabic();
      expect(ar.consentRevokeWarning('أليكس'), startsWith('سيؤدي هذا إلى إيقاف مراقبة أليكس.'));
    });

    test('the digest email field is a short label plus a helper line', () async {
      final ar = await arabic();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(ar.digestPrefsEmailsLabel, 'عناوين البريد الإلكتروني');
      expect(ar.digestPrefsEmailsHelper, 'لتلقي الملخّص (افصل بينها بفواصل)');
      expect(en.digestPrefsEmailsLabel, 'Digest emails');
      expect(en.digestPrefsEmailsHelper, isNotEmpty);
    });

    test('the period selectors use full Arabic words', () async {
      final ar = await arabic();
      expect(ar.daysShort(7), '7 أيام');
      expect(ar.daysShort(14), '14 يومًا');
      expect(ar.daysShort(30), '30 يومًا');
    });

    /// Arabic plural categories, pinned on the numbers the review named: 3 and
    /// 10 are `few` (دقائق), 11 is `many` and 100 is `other` (both دقيقة).
    test('minutes are pluralized in Arabic, not printed as a fixed noun', () async {
      final ar = await arabic();
      expect(ar.minutesShort(3), '3 دقائق');
      expect(ar.minutesShort(10), '10 دقائق');
      expect(ar.minutesShort(11), '11 دقيقة');
      expect(ar.minutesShort(100), '100 دقيقة');
      expect(ar.minutesShort(1), 'دقيقة واحدة');
      expect(ar.minutesShort(2), 'دقيقتان');
      expect(ar.screenTimeValue(3, 10), '3 من 10 دقائق');
      expect(ar.screenTimeValue(45, 120), '45 من 120 دقيقة');
      expect(ar.liveActivityToday('YouTube', 10), 'YouTube · 10 دقائق اليوم');
      expect(ar.dailyLimit(3), 'الحد اليومي: 3 دقائق');
      expect(ar.weekendLimit(10), 'الحد الأقصى لوقت الشاشة في عطلة نهاية الأسبوع: 10 دقائق');
      expect(ar.totalAverage(11, 100), 'الإجمالي: 11 دقيقة · المتوسط: 100 دقيقة يوميًا');
      expect(ar.totalAverage(3, 10), 'الإجمالي: 3 دقائق · المتوسط: 10 دقائق يوميًا');
      expect(ar.totalOverDays(3, 7), 'الإجمالي: 3 دقائق خلال 7 أيام');
      expect(ar.totalOverDays(11, 30), 'الإجمالي: 11 دقيقة خلال 30 يومًا');
      expect(ar.dayTooltip('2026-10-24', 10), '2026-10-24: 10 دقائق');
      expect(ar.dayTooltip('2026-10-24', 100), '2026-10-24: 100 دقيقة');
    });

    test('alert titles come from the category, never the server text', () async {
      final ar = await arabic();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(ar.alertTitleFor('sos', 'SOS pressed', isEnglish: false), 'تم الضغط على زر الاستغاثة');
      expect(ar.alertTitleFor('web_threat', 'Blocked site attempted', isEnglish: false), 'تمت محاولة زيارة موقع محظور');
      expect(ar.alertTitleFor('screen_time_exceeded', 'Daily limit reached', isEnglish: false), 'تم بلوغ الحد اليومي');
      // An unknown category: English keeps the server's own title (it is already
      // English and says more than "Alert"), any other locale shows the generic one.
      expect(ar.alertTitleFor('unknown_category', 'SERVER ENGLISH TITLE', isEnglish: false), 'تنبيه');
      expect(en.alertTitleFor('unknown_category', 'SERVER ENGLISH TITLE', isEnglish: true), 'SERVER ENGLISH TITLE');
      expect(ar.alertTitleGeneric, 'تنبيه');
    });

    /// The drift guard for the blocking finding: the fixture, the mapping and
    /// the screenshot all use the server's categories, and a category the app
    /// stops mapping renders the generic title — which fails here.
    test('every server alert category has its own title in both locales', () async {
      final ar = await arabic();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      for (final category in serverAlertCategories) {
        expect(
          en.alertTitleFor(category, 'SERVER TITLE', isEnglish: true),
          isNot(en.alertTitleGeneric),
          reason: 'en "$category" fell through to the generic title',
        );
        final arTitle = ar.alertTitleFor(category, 'SERVER TITLE', isEnglish: false);
        expect(arTitle, isNot(ar.alertTitleGeneric), reason: 'ar "$category" fell through to the generic title');
        expect(arTitle, isNot('SERVER TITLE'), reason: 'ar "$category" leaked the server English title');
      }
      expect(serverAlertCategories, hasLength(13));
    });

    /// `serverAlertCategories` is a copy of the server's enum, so it is checked
    /// against the server rather than trusted — and every category it names must
    /// reach its own copy twice over: the title above and the short label below
    /// (the review found 11 of 13 labels still printing the raw key). A case
    /// dropped from `alertCategory` or `alertTitleFor` fails here in both
    /// locales before it reaches a screen.
    test('the category list matches InternalAlertSchema', () async {
      final ar = await arabic();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final source = File('../../services/api/src/routes/alerts.ts').readAsStringSync();
      final enumBody = RegExp(r'category: z\.enum\(\[(.*?)\]\)', dotAll: true).firstMatch(source);
      expect(enumBody, isNotNull, reason: 'InternalAlertSchema category enum moved or changed shape');
      final fromServer = RegExp(r'"([a-z_]+)"')
          .allMatches(enumBody!.group(1)!)
          .map((m) => m.group(1)!)
          .toList();
      expect(fromServer, serverAlertCategories);
      for (final category in fromServer) {
        expect(en.alertCategory(category), isNot(category), reason: 'en label "$category" fell back to the raw key');
        expect(ar.alertCategory(category), isNot(category), reason: 'ar label "$category" fell back to the raw key');
        expect(
          en.alertTitleFor(category, 'SERVER TITLE', isEnglish: true),
          isNot(category),
          reason: 'en title "$category" fell back to the raw key',
        );
        expect(
          ar.alertTitleFor(category, 'SERVER TITLE', isEnglish: false),
          isNot(category),
          reason: 'ar title "$category" fell back to the raw key',
        );
      }
      // The fallback is still the raw key, so a category newer than the app
      // reads as itself instead of an empty label.
      expect(en.alertCategory('not_a_category'), 'not_a_category');
      expect(ar.alertCategory('not_a_category'), 'not_a_category');
    });

    test('search risk tags are localized, with the raw key only as a fallback', () async {
      final ar = await arabic();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(ar.searchRiskCategory('substance_use'), 'تعاطي المواد');
      expect(ar.searchRiskCategory('self_harm'), 'إيذاء النفس');
      expect(ar.searchRiskCategory('grooming_risk'), 'استدراج');
      expect(en.searchRiskCategory('substance_use'), 'Substance use');
      expect(en.searchRiskCategory('late_night'), 'late_night');
    });
  });

  /// Review render 03: at 320px the child-detail app bar clipped "تعديل القواعد"
  /// at the left edge. The action is the same route at every width; only its
  /// shape changes, so this group taps it and lands on the rules editor.
  group('child detail app bar — the rules action at narrow widths', () {
    Future<void> pumpChildDetail(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final router = GoRouter(
        initialLocation: '/child/child-1',
        routes: [
          GoRoute(path: '/child/:id', builder: (_, s) => ChildDetailScreen(childId: s.pathParameters['id']!)),
          GoRoute(
            path: '/child/:id/rules',
            builder: (_, s) => RulesEditorScreen(childId: s.pathParameters['id']!),
          ),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(arabicApi())],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        ),
      ));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
    }

    /// The action is painted inside the bar, not clipped by its edge.
    void expectInsideAppBar(WidgetTester tester, Finder action) {
      final rect = tester.getRect(action);
      final bar = tester.getRect(find.byType(AppBar).first);
      expect(rect.left, greaterThanOrEqualTo(bar.left), reason: 'the rules action is clipped at the left edge');
      expect(rect.right, lessThanOrEqualTo(bar.right), reason: 'the rules action is clipped at the right edge');
      expect(rect.width, greaterThan(0));
    }

    testWidgets('320x568: the action is a tooltipped icon and still opens the rules editor', (tester) async {
      await pumpChildDetail(tester, 320);
      final action = find.byKey(const ValueKey('editRulesButton'));
      expect(action, findsOneWidget);
      // The compact shape: an icon with the label as its tooltip, not a text
      // button that runs out of room.
      expect(tester.widget<IconButton>(action).tooltip, 'تعديل القواعد');
      expect(find.widgetWithText(TextButton, 'تعديل القواعد'), findsNothing);
      expectInsideAppBar(tester, action);
      expect(drainExceptions(tester), isEmpty);

      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byType(RulesEditorScreen), findsOneWidget);
    });

    for (final width in <double>[360, 375, 411]) {
      testWidgets('${width.toInt()}px: the label shows in full and opens the rules editor', (tester) async {
        await pumpChildDetail(tester, width);
        final action = find.byKey(const ValueKey('editRulesButton'));
        expect(action, findsOneWidget);
        expect(find.widgetWithText(TextButton, 'تعديل القواعد'), findsOneWidget);
        expectInsideAppBar(tester, action);
        expect(drainExceptions(tester), isEmpty);

        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byType(RulesEditorScreen), findsOneWidget);
      });
    }
  });
}
