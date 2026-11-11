### Android apps — no backup, and the child's secure store no longer falls back to plaintext (osra-security#8 F1, F2)
- Both the child agent and the parent app set `android:allowBackup="false"` with exclude-all
  `data_extraction_rules` (Android 12+) and `backup_rules` (older), so nothing of either app goes to cloud backup or
  moves to a new phone. A restored phone re-pairs or signs in again. `PlayMergedManifestTest` /
  `FullMergedManifestTest` check both build types; `android_backup_off_test.dart` checks the parent app.
- The child agent's `SecureStore` tries the encrypted store twice; if the file stays unreadable it is deleted and
  opened fresh (the phone re-pairs), instead of silently switching to plaintext. Only a Keystore that cannot open any
  encrypted store keeps the plaintext fallback, logged and recorded. Secrets an older build left in plaintext move
  into the encrypted store and the plaintext file is deleted. `SecureStoreOpener` takes its effects as functions, so `SecureStoreOpeningTest` drives it with fakes; `BackupRulesTest` reads the child rule files.
