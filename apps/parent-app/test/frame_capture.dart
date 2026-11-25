import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the real faces the frames are drawn with. The test binding otherwise falls back to a metrics-only font,
/// which renders every word as a solid block — the frame is then *rendered*, uploads fine, and shows nothing a
/// reviewer can read (Arabic Language Bureau, #760). [required] names the families a frame cannot be drawn without;
/// a family that ends up with no face throws instead of passing quietly.
///
/// Both faces are committed under `test/fonts/`. The Arabic one is **Noto Naskh Arabic UI**, because the parent app
/// bundles no font and that is the face Android draws Arabic with — the plain "Noto Naskh Arabic" has looser vertical
/// metrics, so line heights and overflow at 200 % text would not match a real phone (Arabic Bureau, #1110). iOS
/// draws with SF Arabic, which cannot be bundled; the simulator frames are that side's evidence.
Future<void> loadFrameFonts({
  Set<String> required = const {'Roboto'},
  String arabicPath = 'test/fonts/NotoNaskhArabicUI-Regular.ttf',
}) async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '';
  final faces = <String, int>{};

  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var added = 0;
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) {
        loader.addFont(
            Future.value(ByteData.sublistView(file.readAsBytesSync())));
        added++;
      }
    }
    if (added > 0) await loader.load();
    faces[family] = added;
  }

  await load('Roboto', [
    'test/fonts/roboto-regular.ttf',
    'test/fonts/roboto-medium.ttf',
    'test/fonts/roboto-bold.ttf',
  ]);
  await load('MaterialIcons', [
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
  await load('NotoNaskhArabicUI', [arabicPath]);

  final missing = required.where((family) => (faces[family] ?? 0) == 0).toList()..sort();
  if (missing.isNotEmpty) {
    throw StateError('frame fonts: ${missing.join(", ")} loaded no face, so the frame would be drawn in the '
        'test font as solid blocks rather than text. Add the face under test/fonts/.');
  }
}

ThemeData withFrameFonts(ThemeData theme) => theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontFamily: 'Roboto',
        fontFamilyFallback: const ['NotoNaskhArabicUI'],
      ),
    );

Future<void> maybeCaptureFrame(WidgetTester tester, String filename) async {
  final directory = Platform.environment['OSRA_FRAME_DIR'];
  if (directory == null) return;
  for (final image in tester.widgetList<Image>(find.byType(Image))) {
    final element = tester.element(find.byWidget(image));
    await tester.runAsync(() => precacheImage(image.image, element));
  }
  await tester.pump();
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('frameRoot')),
    );
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Could not encode $filename');
    final file = File('$directory/$filename');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  });
}
