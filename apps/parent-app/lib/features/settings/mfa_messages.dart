import '../../api/mfa_api.dart';
import '../../l10n/l10n.dart';

/// Human copy for one API failure. The API deliberately returns one generic
/// answer for several recovery failures, so the text says what was rejected,
/// not which field was wrong.
///
/// [recoveryFlow] changes only what a 401 means: a session flow can tell the
/// parent to sign in again, while the recovery flow's token / credentials have
/// simply stopped being accepted.
String mfaFailureText(
  AppLocalizations l10n,
  MfaFailureKind kind, {
  bool recoveryFlow = false,
}) {
  switch (kind) {
    case MfaFailureKind.unauthorized:
      return recoveryFlow ? l10n.mfaRecoveryExpired : l10n.mfaSessionError;
    case MfaFailureKind.reauthRequired:
      return l10n.mfaReauthFailed;
    case MfaFailureKind.invalidCode:
      return l10n.mfaInvalidCode;
    case MfaFailureKind.mfaNotEnrolled:
      return l10n.mfaNotEnrolled;
    case MfaFailureKind.invalidRecovery:
      return l10n.mfaRecoveryInvalid;
    case MfaFailureKind.rateLimited:
      return l10n.mfaTooManyAttempts;
    case MfaFailureKind.network:
      return l10n.mfaNetworkError;
    case MfaFailureKind.malformed:
      return l10n.mfaRequestFailed;
    case MfaFailureKind.validation:
    case MfaFailureKind.unknown:
      return l10n.mfaRequestFailed;
  }
}
