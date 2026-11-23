// Frames for the Arabic Language Bureau and UI/UX Bureau: tamper alert titles by type (#1010, Karim 23 Nov).
// Not part of CI: run with
//   flutter test tool/frames/tamper_frames_test.dart
// Writes PNGs to build/frames-tamper/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart' show AlertTile;
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

  const types = [
    ('replaced', 'info'),
    ('device_silent', 'critical'),
    ('accessibility', 'critical'),
    ('device_admin_removed', 'critical'),
    ('protection_screen_opened', 'critical'),
    ('parent_pin_locked', 'critical'),
    ('content_filter_disconnected', 'critical'),
    ('private_dns_bypass', 'critical'),
    ('overlay_revoked', 'critical'),
    ('agent_data_cleared', 'warning'),
  ];
  final now = DateTime.now();
  final alerts = [
    for (var i = 0; i < types.length; i++)
      Alert(
        id: 'a$i',
        childId: 'c',
        severity: types[i].$2,
        category: 'tamper',
        title: 'SERVER ENGLISH',
        body: 'SERVER ENGLISH BODY',
        metadata: {'type': types[i].$1},
        createdAt: now.subtract(Duration(minutes: 7 * i + 2)),
      ),
  ];

  for (final locale in const [Locale('en'), Locale('ar')]) {
    for (final scale in [1.0, 2.0]) {
      final name = 'tamper_${locale.languageCode}_${(scale * 100).round()}';
      testWidgets(name, (tester) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = Size(390 * 2, 844 * 2 * (scale > 1 ? 2.6 : 1.4));
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        final t = AppTheme.light;
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: t.copyWith(textTheme: t.textTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: const ['DejaVu'])),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: key, child: child!),
          ),
          home: Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(child: Column(children: [for (final a in alerts) AlertTile(alert: a)])),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/frames-tamper/$name.png');
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      });
    }
  }
}
