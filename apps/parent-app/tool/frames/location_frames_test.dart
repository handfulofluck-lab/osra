// Frames for the UI/UX Bureau (#1004). Not part of CI: run with
//   flutter test tool/frames/location_frames_test.dart
// Writes PNGs to build/frames-1004/. Map tiles need the network, so the map area renders without tiles here;
// the pin, accuracy circle and attribution are real.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

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

  final now = DateTime(2026, 11, 23, 12, 0);
  LocationPing ping(Duration age) => LocationPing(
      deviceId: 'dev-1', lat: 25.11318, lng: 55.20034, accuracyM: 18, timestamp: now.subtract(age));

  final states = <(String, LocationPing, PlacemarkLookup)>[
    ('found', ping(const Duration(minutes: 4)), (lat, lng, l) async => [
          l.languageCode == 'ar'
              ? const Placemark(thoroughfare: 'شارع الخيل', subLocality: 'البرشاء', locality: 'دبي')
              : const Placemark(thoroughfare: 'Al Khail Rd', subLocality: 'Al Barsha', locality: 'Dubai'),
        ]),
    ('finding', ping(const Duration(minutes: 1)), (lat, lng, l) => Completer<List<Placemark>>().future),
    ('stale', ping(const Duration(hours: 2)), (lat, lng, l) async => [
          l.languageCode == 'ar'
              ? const Placemark(subLocality: 'البرشاء', locality: 'دبي')
              : const Placemark(subLocality: 'Al Barsha', locality: 'Dubai'),
        ]),
  ];

  ThemeData withFonts(ThemeData t) => t.copyWith(
        textTheme: t.textTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: const ['DejaVu']),
      );

  for (final locale in const [Locale('en'), Locale('ar')]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        for (final widgetKind in ['card', 'profile']) {
          final name = '${widgetKind}_${locale.languageCode}_${dark ? 'dark' : 'light'}_${(scale * 100).round()}';
          testWidgets(name, (tester) async {
            tester.view.devicePixelRatio = 2;
            tester.view.physicalSize = Size(390 * 2, (widgetKind == 'card' ? 900 : 2600) * scale * 2 / 1.5);
            addTearDown(tester.view.reset);
            final key = GlobalKey();
            final theme = withFonts(dark ? AppTheme.dark : AppTheme.light);
            Widget one((String, LocationPing, PlacemarkLookup) s) => ProviderScope(
                  overrides: [
                    clockProvider.overrideWithValue(() => now),
                    placemarkLookupProvider.overrideWithValue(s.$3),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('State: ${s.$1}', style: theme.textTheme.labelSmall),
                      const SizedBox(height: 4),
                      if (widgetKind == 'card')
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Icon(Icons.location_on_outlined, size: 14),
                              const SizedBox(width: 4),
                              Expanded(
                                child: PlaceSummaryLine(
                                  ping: s.$2,
                                  style: theme.textTheme.bodySmall,
                                  onTap: () {},
                                ),
                              ),
                            ]),
                          ),
                        )
                      else
                        ChildLocationCard(ping: s.$2, childName: 'Alex'),
                    ]),
                  ),
                );
            await tester.pumpWidget(MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(size: const Size(390, 4000), textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: RepaintBoundary(
                      key: key,
                      child: ColoredBox(
                        color: theme.colorScheme.surface,
                        child: SizedBox(width: 390, child: Column(children: [for (final s in states) one(s)])),
                      ),
                    ),
                  ),
                ),
              ),
            ));
            await tester.pump(const Duration(milliseconds: 200));
            await tester.pump(const Duration(milliseconds: 200));
            await tester.runAsync(() async {
              final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              final out = File('build/frames-1004/$name.png');
              out.parent.createSync(recursive: true);
              out.writeAsBytesSync(bytes!.buffer.asUint8List());
            });
          });
        }
      }
    }
  }
}
