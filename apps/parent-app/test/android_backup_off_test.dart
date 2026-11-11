// osra-security#8 F1: the parent app's data (the session in flutter_secure_storage, settings) must never be backed up
// or moved to a new phone. flutter_secure_storage's own docs require backup off: a restored copy cannot be decrypted
// without its Keystore key. A restored phone signs in again.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the release manifest turns Android backup off with exclude-all rules', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
  });

  test('the rules exclude every domain from cloud backup, device transfer and legacy backup', () {
    final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml').readAsStringSync();
    final legacy = File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync();
    for (final section in ['<cloud-backup>', '<device-transfer>']) {
      final start = rules.indexOf(section);
      expect(start, isNonNegative, reason: section);
      final body = rules.substring(start, rules.indexOf(section.replaceFirst('<', '</')));
      for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
        expect(body, contains('<exclude domain="$domain" path="." />'), reason: '$section $domain');
      }
    }
    for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
      expect(legacy, contains('<exclude domain="$domain" path="." />'), reason: 'legacy $domain');
    }
  });
}
