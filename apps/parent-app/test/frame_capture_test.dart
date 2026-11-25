import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'frame_capture.dart';

/// #760: a frame drawn in the test font is a picture of solid blocks, and the run that produced it still passes.
/// These rows hold the loader to the opposite: a family a frame needs either loads a real face or throws.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the faces the frames need are committed and load', () async {
    await loadFrameFonts(required: const {'Roboto', 'NotoNaskhArabicUI'});
    expect(File('test/fonts/NotoNaskhArabicUI-Regular.ttf').existsSync(), isTrue,
        reason: 'the Arabic face ships with the tests instead of the SDK');
  });

  test('a required family with no face throws instead of drawing blocks', () async {
    await expectLater(
      loadFrameFonts(
        required: const {'NotoNaskhArabicUI'},
        arabicPath: 'test/fonts/not-a-real-font.ttf',
      ),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('NotoNaskhArabicUI'))),
    );
  });

  test('an optional family that is absent does not throw', () async {
    // MaterialIcons is optional: a missing icon font is a box in one row, not a frame nobody can read.
    await loadFrameFonts();
  });
}
