import 'package:flutter/foundation.dart';

import '../providers/onboarding_provider.dart';

/// #972: holds an alert id tapped from an OS notification (cold start or warm start) until
/// authentication and startup checks finish, then hands it to [GoRouter] to open `/alerts/:id`.
class NotificationTapController extends ChangeNotifier {
  String? _pendingAlertId;

  String? get pendingAlertId => _pendingAlertId;

  /// Records a notification tap payload. Rejects empty values or route-control characters
  /// so a malformed payload can never steer navigation outside `/alerts/:id`.
  void recordTap(String? payload) {
    final trimmed = payload?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (trimmed.contains('/') || trimmed.contains('?') || trimmed.contains('#')) return;
    _pendingAlertId = trimmed;
    notifyListeners();
  }

  /// Returns and clears the queued alert id once navigation consumes it.
  String? consumePendingAlertId() {
    final id = _pendingAlertId;
    _pendingAlertId = null;
    return id;
  }

  /// Clears any queued alert id (used in tests and sign-out cleanup).
  void clear() {
    _pendingAlertId = null;
  }
}

/// Global notification-tap queue observed by the root [GoRouter] in `app.dart`.
final notificationTapController = NotificationTapController();

/// Computes the post-authentication redirect target for a queued notification tap.
///
/// Never consumes [controller.pendingAlertId] before authentication finishes, so a cold-start
/// tap while signed out survives `/starting` -> `/login` and opens `/alerts/:id` right after sign-in.
String? resolveNotificationAlertRedirect({
  required bool authenticated,
  required bool onboardingComplete,
  required OnboardingStep onboardingStep,
  required NotificationTapController controller,
}) {
  if (!authenticated) return null;
  if (!onboardingComplete && onboardingStep != OnboardingStep.none) return null;
  final id = controller.consumePendingAlertId();
  if (id == null) return null;
  return '/alerts/${Uri.encodeComponent(id)}';
}
