import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, immutable;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../providers/auth_provider.dart';
import '../providers/onboarding_provider.dart';
import 'push_registration.dart';

/// Persisted flag recording that OSRA has shown its one-time post-sign-in /
/// post-setup notification permission prompt (#1173).
const kPushPermissionPromptedKey = 'push_permission_prompted_v1';

/// Platform seam for OS notification permission status, one-time prompting,
/// opening system notification settings, and FCM token rotation (#1173).
abstract class NotificationPermissionPlatform {
  const NotificationPermissionPlatform();

  /// Returns `true` when OS notifications are enabled for this app, `false`
  /// when blocked/denied in OS settings, or `null` when unknown (e.g. headless
  /// test environment without a platform channel, or iOS `notDetermined`).
  Future<bool?> areNotificationsEnabled();

  /// Requests OS notification permission (`POST_NOTIFICATIONS` on Android 13+,
  /// APNs alert/sound/badge on iOS). Returns `true` if granted, `false` if
  /// denied, or `null` when no platform channel is attached.
  Future<bool?> requestPermission();

  /// Opens the system app notification settings page.
  Future<bool> openNotificationSettings();

  /// Emits rotated push tokens while the app is running.
  Stream<String> get onTokenRefresh => const Stream.empty();
}

class DeviceNotificationPermissionPlatform
    extends NotificationPermissionPlatform {
  const DeviceNotificationPermissionPlatform();

  static const _androidChannel =
      MethodChannel('dev.familyshield.parent/notifications');

  Future<bool> _ensureFirebaseReady() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool?> areNotificationsEnabled() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        return await _androidChannel.invokeMethod<bool>(
          'areNotificationsEnabled',
        );
      } on MissingPluginException {
        return null;
      } on PlatformException {
        return null;
      }
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (!await _ensureFirebaseReady()) return null;
      try {
        final settings =
            await FirebaseMessaging.instance.getNotificationSettings();
        return switch (settings.authorizationStatus) {
          AuthorizationStatus.authorized ||
          AuthorizationStatus.provisional =>
            true,
          AuthorizationStatus.denied => false,
          AuthorizationStatus.notDetermined => null,
        };
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Future<bool?> requestPermission() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        return await _androidChannel.invokeMethod<bool>(
          'requestPostNotifications',
        );
      } on MissingPluginException {
        return null;
      } on PlatformException {
        return null;
      }
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (!await _ensureFirebaseReady()) return null;
      try {
        final settings = await FirebaseMessaging.instance.requestPermission();
        return switch (settings.authorizationStatus) {
          AuthorizationStatus.authorized ||
          AuthorizationStatus.provisional =>
            true,
          AuthorizationStatus.denied ||
          AuthorizationStatus.notDetermined =>
            false,
        };
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Future<bool> openNotificationSettings() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final opened = await _androidChannel.invokeMethod<bool>(
          'openNotificationSettings',
        );
        return opened ?? false;
      } on MissingPluginException {
        return false;
      } on PlatformException {
        return false;
      }
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        return await launchUrl(
          Uri.parse('app-settings:'),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  @override
  Stream<String> get onTokenRefresh async* {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (!await _ensureFirebaseReady()) return;
    try {
      yield* FirebaseMessaging.instance.onTokenRefresh;
    } catch (_) {
      // Ignore stream errors on unsupported/headless targets.
    }
  }
}

final notificationPermissionPlatformProvider =
    Provider<NotificationPermissionPlatform>(
  (_) => const DeviceNotificationPermissionPlatform(),
);

@immutable
class NotificationPermissionState {
  final bool? osNotificationsEnabled;
  final PushRegistrationOutcome? lastPushOutcome;

  const NotificationPermissionState({
    this.osNotificationsEnabled,
    this.lastPushOutcome,
  });

  /// True when OS notifications are explicitly off (`false`) or the push source
  /// reported a permission denial (`PushRegistrationOutcome.denied`).
  bool get showAlertsOffBanner =>
      osNotificationsEnabled == false ||
      (osNotificationsEnabled == null &&
          lastPushOutcome == PushRegistrationOutcome.denied);

  NotificationPermissionState copyWith({
    Object? osNotificationsEnabled = _unset,
    Object? lastPushOutcome = _unset,
  }) {
    return NotificationPermissionState(
      osNotificationsEnabled: identical(osNotificationsEnabled, _unset)
          ? this.osNotificationsEnabled
          : osNotificationsEnabled as bool?,
      lastPushOutcome: identical(lastPushOutcome, _unset)
          ? this.lastPushOutcome
          : lastPushOutcome as PushRegistrationOutcome?,
    );
  }
}

const _unset = Object();

class NotificationPermissionController
    extends StateNotifier<NotificationPermissionState> {
  NotificationPermissionController(this._ref)
      : super(const NotificationPermissionState()) {
    _tokenSub = _ref
        .read(notificationPermissionPlatformProvider)
        .onTokenRefresh
        .listen(_handleTokenRefresh, onError: (_) {});
  }

  final Ref _ref;
  StreamSubscription<String>? _tokenSub;
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _tokenSub?.cancel();
    super.dispose();
  }

  void _setStateSafe(NotificationPermissionState next) {
    if (_disposed) return;
    state = next;
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _serial.then((_) async {
      if (_disposed) return;
      await task();
    }).catchError((_) {});
    _serial = next;
    return next;
  }

  void _handleTokenRefresh(String token) {
    if (token.trim().isEmpty) return;
    unawaited(_enqueue(() async {
      final auth = _ref.read(authProvider);
      if (!auth.isAuthenticated) return;
      final outcome = await _ref
          .read(authProvider.notifier)
          .syncPushRegistration(refreshedToken: token.trim());
      _setStateSafe(state.copyWith(lastPushOutcome: outcome));
    }));
  }

  /// Evaluates notification permission and push-token registration when
  /// [readyForAlerts] changes (`auth.isAuthenticated && !onboarding.inProgress`).
  ///
  /// Never prompts on cold start before sign-in or mid-wizard during first-run
  /// family setup (#1173).
  Future<void> evaluate({required bool readyForAlerts}) => _enqueue(() async {
        if (!readyForAlerts) {
          if (!_ref.read(authProvider).isAuthenticated) {
            _setStateSafe(const NotificationPermissionState());
          }
          return;
        }

        final platform = _ref.read(notificationPermissionPlatformProvider);
        var enabled = await platform.areNotificationsEnabled();

        SharedPreferences? prefs;
        try {
          prefs = await SharedPreferences.getInstance();
        } catch (_) {}
        final alreadyPrompted =
            prefs?.getBool(kPushPermissionPromptedKey) ?? false;

        if (!alreadyPrompted && enabled != true) {
          final requested = await platform.requestPermission();
          if (requested != null) {
            enabled = requested;
            try {
              await prefs?.setBool(kPushPermissionPromptedKey, true);
            } catch (_) {}
          }
        }

        if (_disposed || !_ref.read(authProvider).isAuthenticated) return;

        if (enabled == false) {
          _setStateSafe(
            state.copyWith(
              osNotificationsEnabled: false,
              lastPushOutcome: PushRegistrationOutcome.denied,
            ),
          );
          return;
        }

        final outcome =
            await _ref.read(authProvider.notifier).syncPushRegistration();
        final resolvedEnabled =
            outcome == PushRegistrationOutcome.denied ? false : enabled;
        if (outcome == PushRegistrationOutcome.registered ||
            outcome == PushRegistrationOutcome.denied) {
          try {
            await prefs?.setBool(kPushPermissionPromptedKey, true);
          } catch (_) {}
        }
        _setStateSafe(
          state.copyWith(
            osNotificationsEnabled: resolvedEnabled,
            lastPushOutcome: outcome,
          ),
        );
      });

  /// Re-checks OS notification status on `AppLifecycleState.resumed` (#1173):
  /// clears the Home banner once notifications are turned on in Settings and
  /// immediately registers any missing or changed push token.
  Future<void> onAppResumed() => _enqueue(() async {
        final auth = _ref.read(authProvider);
        final onboarding = _ref.read(onboardingProvider);
        if (!auth.isAuthenticated ||
            !onboarding.loaded ||
            onboarding.inProgress) {
          return;
        }

        final platform = _ref.read(notificationPermissionPlatformProvider);
        final enabled = await platform.areNotificationsEnabled();
        if (_disposed || !_ref.read(authProvider).isAuthenticated) return;

        if (enabled == false) {
          _setStateSafe(
            state.copyWith(
              osNotificationsEnabled: false,
              lastPushOutcome: PushRegistrationOutcome.denied,
            ),
          );
          return;
        }

        final outcome =
            await _ref.read(authProvider.notifier).syncPushRegistration();
        final resolvedEnabled =
            outcome == PushRegistrationOutcome.denied ? false : enabled;
        _setStateSafe(
          state.copyWith(
            osNotificationsEnabled: resolvedEnabled,
            lastPushOutcome: outcome,
          ),
        );
      });

  Future<bool> openSettings() =>
      _ref.read(notificationPermissionPlatformProvider).openNotificationSettings();
}

final notificationPermissionControllerProvider = StateNotifierProvider<
    NotificationPermissionController, NotificationPermissionState>(
  (ref) => NotificationPermissionController(ref),
);

/// App-wide coordinator watching auth + onboarding readiness and foreground
/// resume so `POST_NOTIFICATIONS` is requested once after sign-in/setup and
/// re-checked whenever the parent returns from system Settings (#1173).
final notificationLifecycleSyncProvider = Provider<void>((ref) {
  final controller = ref.watch(notificationPermissionControllerProvider.notifier);

  bool isReady() {
    final auth = ref.read(authProvider);
    final onboarding = ref.read(onboardingProvider);
    return auth.isAuthenticated && onboarding.loaded && !onboarding.inProgress;
  }

  unawaited(controller.evaluate(readyForAlerts: isReady()));

  ref.listen<bool>(
    authProvider.select((s) => s.isAuthenticated),
    (_, __) => unawaited(controller.evaluate(readyForAlerts: isReady())),
  );
  ref.listen<(bool, bool)>(
    onboardingProvider.select((s) => (s.loaded, s.inProgress)),
    (_, __) => unawaited(controller.evaluate(readyForAlerts: isReady())),
  );

  final lifecycle = AppLifecycleListener(
    onResume: () => unawaited(controller.onAppResumed()),
  );
  ref.onDispose(lifecycle.dispose);
});