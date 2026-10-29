import 'package:dio/dio.dart';

import '../../api/permission_errors.dart';
import '../../l10n/l10n.dart';

/// Turns the API's raw auth error into what the parent can act on.
///
/// [AuthNotifier] keeps the server's own string because the non-wizard login
/// screen shows it verbatim; the wizard is the first-run path, so it names the
/// two causes a non-engineer can actually fix.
String onboardingAuthError(AppLocalizations l10n, String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('invalid_credentials') ||
      lower.contains('invalid credential') ||
      lower.contains('incorrect password') ||
      lower.contains('unauthorized')) {
    return l10n.onboardingWrongPassword;
  }
  if (lower.contains('invalid authentication code') || lower.contains('invalid_code')) {
    return l10n.onboardingInvalidMfaCode;
  }
  if (isNetworkMessage(lower)) return l10n.onboardingNoNetwork;
  return raw;
}

/// One honest sentence for a failed `POST /v1/family/children`.
String onboardingChildError(AppLocalizations l10n, DioException error) {
  final status = error.response?.statusCode;
  if (status == 428) {
    // #437 A2: a region mismatch is the one 428 the wizard can act on; collapsing it into
    // "consent required" sent a parent to ask for a consent the region had already refused.
    final region = consentRefusalRegionLabel(l10n, error);
    if (region != null) return l10n.addChildConsentRegion(region);
    return l10n.onboardingConsentRequired;
  }
  if (status == 403) return l10n.onboardingOwnerOnly;
  if (status == 400 || status == 422) return l10n.onboardingChildInvalid;
  if (error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      isNetworkMessage('${error.message ?? ''} ${error.error ?? ''}'.toLowerCase())) {
    return l10n.onboardingNoNetwork;
  }
  return l10n.onboardingChildFailed;
}

/// Dio folds DNS/socket failures into a message rather than a distinct type on
/// every platform, so both paths are checked.
bool isNetworkMessage(String lower) =>
    lower.contains('socket') ||
    lower.contains('connection') ||
    lower.contains('network') ||
    lower.contains('timed out') ||
    lower.contains('timeout') ||
    lower.contains('failed host lookup');
