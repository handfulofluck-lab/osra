import 'package:flutter/foundation.dart';

import '../providers/onboarding_provider.dart';

/// #972, #1028: holds an alert destination tapped from an OS notification (cold start or
/// warm start) until authentication and startup checks finish, then hands it to [GoRouter]
/// to open `/alerts/:id` (or `/alerts` when a generic wake tap is ambiguous or signed out).
class NotificationTapController extends ChangeNotifier {
  String? _pendingAlertId;
  bool _pendingAlertsFeed = false;

  String? get pendingAlertId => _pendingAlertId;
  bool get pendingAlertsFeed => _pendingAlertsFeed;

  /// The queued route destination (`/alerts/:id` or `/alerts`), or `null` if none.
  String? get pendingDestination {
    final id = _pendingAlertId;
    if (id != null) return '/alerts/${Uri.encodeComponent(id)}';
    if (_pendingAlertsFeed) return '/alerts';
    return null;
  }

  /// Records a notification tap payload. Rejects empty values or route-control characters
  /// so a malformed payload can never steer navigation outside `/alerts/:id`.
  void recordTap(String? payload) {
    final trimmed = payload?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (trimmed.contains('/') || trimmed.contains('?') || trimmed.contains('#')) return;
    _pendingAlertId = trimmed;
    _pendingAlertsFeed = false;
    notifyListeners();
  }

  /// Records a generic alert notification tap (e.g. shipping `{w: "1"}` wake with no
  /// single unambiguous alert id) so the router opens `/alerts` after authentication.
  void recordAlertsFeedTap() {
    _pendingAlertId = null;
    _pendingAlertsFeed = true;
    notifyListeners();
  }

  /// Returns and clears the queued alert id once navigation consumes it.
  String? consumePendingAlertId() {
    final id = _pendingAlertId;
    _pendingAlertId = null;
    return id;
  }

  /// Returns and clears the queued route destination (`/alerts/:id` or `/alerts`).
  String? consumePendingDestination() {
    final id = _pendingAlertId;
    if (id != null) {
      _pendingAlertId = null;
      _pendingAlertsFeed = false;
      return '/alerts/${Uri.encodeComponent(id)}';
    }
    if (_pendingAlertsFeed) {
      _pendingAlertsFeed = false;
      return '/alerts';
    }
    return null;
  }

  /// Clears any queued destination (used in tests and sign-out cleanup).
  void clear() {
    _pendingAlertId = null;
    _pendingAlertsFeed = false;
  }
}

/// Global notification-tap queue observed by the root [GoRouter] in `app.dart`.
final notificationTapController = NotificationTapController();

/// Computes the post-authentication redirect target for a queued notification tap.
///
/// Never consumes [controller.pendingDestination] before authentication finishes, so a cold-start
/// tap while signed out survives `/starting` -> `/login` and opens `/alerts/:id` or `/alerts`
/// right after sign-in.
String? resolveNotificationAlertRedirect({
  required bool authenticated,
  required bool onboardingComplete,
  required OnboardingStep onboardingStep,
  required NotificationTapController controller,
}) {
  if (!authenticated) return null;
  if (!onboardingComplete && onboardingStep != OnboardingStep.none) return null;
  return controller.consumePendingDestination();
}
