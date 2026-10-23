import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What the app remembers between launches about a reset: the request id and
/// the address the parent typed. **Never the password.** The password is asked
/// again by the waiting screen for a single `/status` call and then dropped.
///
/// The two values are all `/reset/status` needs, together with that password,
/// to rebuild the stage. A partial record (one key without the other) is not
/// usable and reads as absent.
@immutable
class StoredMfaReset {
  final String requestId;
  final String email;

  const StoredMfaReset({required this.requestId, required this.email});
}

/// The persistent half of [StoredMfaReset], in `flutter_secure_storage` beside
/// the session tokens (`jwt`, `refresh` in `AuthNotifier` / `ApiClient`).
///
/// Every read and write swallows a storage failure: a keyboard or keystore
/// problem must not break the reset flow, it only costs the resume. Nothing
/// here is a credential.
class MfaResetStore {
  const MfaResetStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const requestIdKey = 'mfa_reset_request_id';
  static const emailKey = 'mfa_reset_email';

  Future<StoredMfaReset?> read() async {
    try {
      final requestId = await _storage.read(key: requestIdKey);
      final email = await _storage.read(key: emailKey);
      if (requestId == null || requestId.isEmpty || email == null || email.isEmpty) {
        return null;
      }
      return StoredMfaReset(requestId: requestId, email: email);
    } catch (_) {
      return null;
    }
  }

  Future<void> save({required String requestId, required String email}) async {
    if (requestId.isEmpty || email.isEmpty) return;
    try {
      await _storage.write(key: requestIdKey, value: requestId);
      await _storage.write(key: emailKey, value: email);
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: requestIdKey);
      await _storage.delete(key: emailKey);
    } catch (_) {}
  }
}
