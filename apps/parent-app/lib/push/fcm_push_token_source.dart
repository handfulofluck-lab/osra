import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_registration.dart';

/// The FCM source behind [PushTokenSource] (roadmap 3.9 / #360).
///
/// **Nothing here throws.** The parent app ships in three shapes and only one of them can
/// mint a token:
///
///  - **No `google-services.json`** — the rule from #317. The file stays out of the repository,
///    so a build made from a clean clone has no Firebase config and `Firebase.initializeApp()`
///    fails. Push is not broken in that build; it is *absent*, and the seam says so with
///    [PushPermission.unavailable] rather than pretending the parent refused.
///  - **Config present, the OS declines** — `denied`. Different fact, different consequence:
///    the app must not ask again in this session.
///  - **Config present and granted** — a token, which [PushRegistration] forwards to
///    `POST /v1/me/push-token`.
///
/// The distinction between "not configured" and "refused" is the whole reason [PushPermission]
/// has three values, so this source is careful never to collapse them.
class FcmPushTokenSource implements PushTokenSource {
  FcmPushTokenSource({Future<void> Function()? ensureInitialized})
      : _ensureInitialized = ensureInitialized ?? _initializeDefault;

  final Future<void> Function() _ensureInitialized;

  /// Set once initialisation has succeeded, so a build without config pays for the failure
  /// exactly once rather than on every poll and every sign-in.
  bool _ready = false;
  bool _failed = false;

  static Future<void> _initializeDefault() async {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  }

  /// True when the SDK is usable: config was found and initialisation succeeded.
  Future<bool> _available() async {
    if (_ready) return true;
    if (_failed) return false;
    try {
      await _ensureInitialized();
      _ready = true;
      return true;
    } catch (_) {
      // No config (or a platform without Firebase): absent, not denied.
      _failed = true;
      return false;
    }
  }

  @override
  Future<PushPermission> requestPermission() async {
    if (!await _available()) return PushPermission.unavailable;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized || AuthorizationStatus.provisional => PushPermission.granted,
        AuthorizationStatus.denied => PushPermission.denied,
        // `notDetermined` means the prompt was not shown; the parent has decided nothing yet, so
        // this is not a refusal. The seam has no third mobile state, and reporting `denied` would
        // stop the app asking next launch, so it is treated as a soft denial for this session only.
        AuthorizationStatus.notDetermined => PushPermission.denied,
      };
    } catch (_) {
      // The plugin is present but unusable on this platform (or in a unit test): no SDK.
      return PushPermission.unavailable;
    }
  }

  @override
  Future<String?> token() async {
    if (!await _available()) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      // Permission given but no token yet: an asynchronous registration can still be in flight.
      return null;
    }
  }
}

/// The source a running build should use (roadmap 3.9 / #360).
///
/// FCM on both mobile targets: `firebase_messaging` mints an FCM token on Android and on iOS, so a
/// parent `ios` token is sent through the FCM provider and never through APNs (#391 review). The parent
/// app has no web target, so there is no third case; [UnavailablePushTokenSource] remains for a build
/// where Firebase has no configuration and a token cannot be minted at all.
PushTokenSource defaultPushSource() => FcmPushTokenSource();
