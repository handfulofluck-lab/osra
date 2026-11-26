import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadFrameFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) {
        loader.addFont(
            Future.value(ByteData.sublistView(file.readAsBytesSync())));
      }
    }
    await loader.load();
  }

  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '';
  await load('Roboto', [
    'test/fonts/roboto-regular.ttf',
    'test/fonts/roboto-medium.ttf',
    'test/fonts/roboto-bold.ttf',
  ]);
  await load('MaterialIcons', [
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
  await load('NotoNaskhArabic', [
    '$sdk/engine/src/flutter/txt/third_party/fonts/NotoNaskhArabic-Regular.ttf',
  ]);
}

ThemeData withFrameFonts(ThemeData theme) => theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontFamily: 'Roboto',
        fontFamilyFallback: const ['NotoNaskhArabic'],
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
