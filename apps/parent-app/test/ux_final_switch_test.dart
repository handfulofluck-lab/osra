import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every per-screen UX switch (`OSRA_UX_P07`, `OSRA_UX_P09`, ...) must fall back to `OSRA_UX_FINAL`.
///
/// Test and store builds pass only `--dart-define=OSRA_UX_FINAL=true`. A switch that defaults to
/// plain `false` hides its merged screen from those builds, which is what happened to P-09, P-12,
/// P-15, P-17 and P-20 before the 28 Nov test.
void main() {
  test('every OSRA_UX_Pxx switch falls back to OSRA_UX_FINAL', () {
    final switchPattern = RegExp(r"bool\.fromEnvironment\(\s*'OSRA_UX_P\w+'([^;]*);");
    final missing = <String>[];
    var found = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in switchPattern.allMatches(source)) {
        found++;
        if (!match.group(1)!.contains("'OSRA_UX_FINAL'")) {
          missing.add('${entity.path}: ${match.group(0)!.split('\n').first}');
        }
      }
    }
    expect(found, greaterThan(0), reason: 'no OSRA_UX_Pxx switches found; did the pattern drift?');
    expect(missing, isEmpty, reason: 'these switches ignore OSRA_UX_FINAL:\n${missing.join('\n')}');
  });
}
