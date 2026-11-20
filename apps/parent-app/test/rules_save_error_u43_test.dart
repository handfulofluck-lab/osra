import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

Future<void> _loadBundledFonts() async {
  final sep = Platform.pathSeparator;
  Directory? fontsDir;
  for (final rel in ['test${sep}fonts', 'apps${sep}parent-app${sep}test${sep}fonts']) {
    final d = Directory(rel);
    if (d.existsSync()) {
      fontsDir = d;
      break;
    }
  }
  if (fontsDir == null) return;
  final loader = FontLoader('Roboto');
  for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
    final f = File('${fontsDir.path}$sep$name');
    if (f.existsSync()) {
      final bytes = await f.readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadBundledFonts);

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> pumpEditor(
    WidgetTester tester,
    FakeApiClient api, {
    Locale locale = const Locale('en'),
    bool dark = false,
    double width = 320,
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const RulesEditorScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('offline save keeps edits intact, shows saveFailed inline banner above 52dp Save, and Retry succeeds', (tester) async {
    var putAttempts = 0;
    final payload = ruleSetPayload('child-1');
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => payload,
      'PUT /v1/rules/child-1': (_) {
        putAttempts++;
        if (putAttempts == 1) return const FakeNetworkError();
        return {'ok': true};
      },
    });

    await pumpEditor(tester, api, width: 320, textScale: 2.0);
    final l10n = lookupAppLocalizations(const Locale('en'));

    // Edit the daily limit slider so we prove edits stay on screen after failed save.
    final sliderFinder = find.byType(Slider).first;
    await tester.drag(sliderFinder, const Offset(40, 0));
    await tester.pumpAndSettle();
    final editedText = tester.widget<Text>(find.textContaining('Daily limit:').first).data!;

    final saveBtn = find.byKey(const ValueKey('rules-save-button'));
    expect(tester.getRect(saveBtn).height, greaterThanOrEqualTo(52.0));

    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    // No full-page error: edited limit and sliders stay visible on screen.
    expect(find.text(editedText), findsOneWidget);
    expect(find.byType(Slider), findsWidgets);

    // Inline banner sits directly ABOVE the Save button with Retry action and offline copy.
    final banner = find.byKey(const ValueKey('rules-save-error-banner'));
    expect(banner, findsOneWidget);
    expect(find.text(l10n.saveFailed), findsOneWidget);
    expect(tester.getRect(banner).bottom, lessThanOrEqualTo(tester.getRect(saveBtn).top));
    expect(find.byKey(const ValueKey('rules-save-retry')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('rules-save-retry')));
    await tester.tap(find.byKey(const ValueKey('rules-save-retry')));
    await tester.pumpAndSettle();
    expect(putAttempts, 2);
    expect(banner, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server refusal uses saveFailedServer without connection copy or raw status/request ids, and preserves Save width while saving', (tester) async {
    final gate = Completer<Map<String, dynamic>>();
    var call = 0;
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
      'PUT /v1/rules/child-1': (_) {
        call++;
        if (call == 1) {
          return const FakeHttpError(503, {'error': 'internal_db_timeout', 'requestId': 'req-998877'});
        }
        return FakeDeferred(gate.future);
      },
    });

    await pumpEditor(tester, api, width: 320, textScale: 2.0);
    final l10n = lookupAppLocalizations(const Locale('en'));

    final saveBtn = find.byKey(const ValueKey('rules-save-button'));
    final idleSize = tester.getSize(saveBtn);
    expect(idleSize.height, greaterThanOrEqualTo(52.0));

    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(find.text(l10n.saveFailedServer), findsOneWidget);
    expect(find.text(l10n.saveFailed), findsNothing);
    expect(find.textContaining('503'), findsNothing);
    expect(find.textContaining('req-998877'), findsNothing);
    expect(find.textContaining('internal_db_timeout'), findsNothing);

    // Retry and keep mid-flight spinner on screen to verify Save button keeps width & height.
    await tester.ensureVisible(find.byKey(const ValueKey('rules-save-retry')));
    await tester.tap(find.byKey(const ValueKey('rules-save-retry')));
    await tester.pump();
    final savingSize = tester.getSize(saveBtn);
    expect(savingSize.width, closeTo(idleSize.width, 0.1));
    expect(savingSize.height, greaterThanOrEqualTo(52.0));
    expect(find.descendant(of: saveBtn, matching: find.byType(CircularProgressIndicator)), findsOneWidget);

    gate.complete({'ok': true});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('Arabic save error banner renders at 320px/200% without overflow (dark=$dark)', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
        'PUT /v1/rules/child-1': (_) => const FakeHttpError(500),
      });

      await pumpEditor(tester, api, locale: const Locale('ar'), dark: dark, width: 320, textScale: 2.0);
      final l10n = lookupAppLocalizations(const Locale('ar'));
      await tester.tap(find.byKey(const ValueKey('rules-save-button')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.saveFailedServer), findsOneWidget);
      expect(find.byKey(const ValueKey('rules-save-retry')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
