// Frames for the UI/UX Bureau: the new Apps tab (Karim, 23 Nov). Not part of CI: run with
//   flutter test tool/frames/apps_frames_test.dart
// Writes PNGs to build/frames-apps/. The icons are synthetic samples (tool/frames/sample_icons.json).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_apps_list.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '';
  setUpAll(() async {
    await _font('Roboto', ['test/fonts/roboto-regular.ttf', 'test/fonts/roboto-medium.ttf', 'test/fonts/roboto-bold.ttf']);
    await _font('DejaVu', ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf']);
    await _font('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  final icons = Map<String, String>.from(jsonDecode(File('tool/frames/sample_icons.json').readAsStringSync()) as Map);
  final report = InstalledAppsReport(apps: [
    InstalledApp(packageId: 'a.camera', label: 'Instagram', iconUrl: icons['camera'], essential: false),
    const InstalledApp(packageId: 'a.notes', label: 'Notes', essential: false),
    InstalledApp(packageId: 'a.chat', label: 'WhatsApp', iconUrl: icons['chat'], essential: false),
    InstalledApp(packageId: 'a.blocks', label: 'Roblox', iconUrl: icons['blocks'], essential: false),
    InstalledApp(packageId: 'a.video', label: 'YouTube', iconUrl: icons['video'], essential: false),
    InstalledApp(packageId: 'a.game', label: 'Brawl Stars', iconUrl: icons['game'], essential: false),
    InstalledApp(packageId: 'a.maps', label: 'Maps', iconUrl: icons['maps'], essential: false),
    const InstalledApp(packageId: 'a.phone', label: 'Phone', isSystem: true, essential: true),
  ]);
  const rules = RuleSet(appRules: [
    AppRule(packageId: 'a.blocks', appName: 'Roblox', action: 'block'),
    AppRule(packageId: 'a.video', appName: 'YouTube', action: 'time_limit', dailyLimitMinutes: 60),
  ]);

  ThemeData withFonts(ThemeData t) =>
      t.copyWith(textTheme: t.textTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: const ['DejaVu']));

  for (final locale in const [Locale('en'), Locale('ar')]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        for (final sheet in [false, true]) {
          if (sheet && (dark || scale != 1.0)) continue;
          final name =
              'apps_${sheet ? 'sheet_' : ''}${locale.languageCode}_${dark ? 'dark' : 'light'}_${(scale * 100).round()}';
          testWidgets(name, (tester) async {
            tester.view.devicePixelRatio = 2;
            tester.view.physicalSize = Size(390 * 2, 844 * 2 * (scale > 1 ? 1.8 : 1));
            addTearDown(tester.view.reset);
            final key = GlobalKey();
            final theme = withFonts(dark ? AppTheme.dark : AppTheme.light);
            await tester.pumpWidget(ProviderScope(
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: key, child: child!),
                ),
                home: Scaffold(
                  body: SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: ChildAppsList(childId: 'c', ruleSet: rules, report: report, onInsight: (_) {}),
                    ),
                  ),
                ),
              ),
            ));
            await tester.pumpAndSettle();
            if (sheet) {
              await tester.tap(find.byKey(const ValueKey('appRow-a.chat')));
              await tester.pumpAndSettle();
            }
            // Let the icon images decode.
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
            await tester.pump();
            await tester.runAsync(() async {
              final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              final out = File('build/frames-apps/$name.png');
              out.parent.createSync(recursive: true);
              out.writeAsBytesSync(bytes!.buffer.asUint8List());
            });
          });
        }
      }
    }
  }
}
