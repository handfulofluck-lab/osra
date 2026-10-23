import '../../api/mfa_reset_api.dart';
import '../../l10n/l10n.dart';

/// Human copy for one reset failure.
///
/// The API deliberately collapses several causes into one answer (an unknown
/// address and a wrong password are both `invalid_credentials`; an unknown
/// request, an expired code and a wrong code are all `invalid_witness`), so
/// this says what was rejected, never which field or why. [attemptsRemaining]
/// is used only when the server sent it.
///
/// A screen that owns a more specific sentence for one kind checks that kind
/// first and falls back here for everything else.
String mfaResetFailureText(
  AppLocalizations l10n,
  MfaResetFailureKind kind, {
  int? attemptsRemaining,
}) {
  switch (kind) {
    case MfaResetFailureKind.invalidCredentials:
      return l10n.mfaResetInvalidCredentials;
    case MfaResetFailureKind.mfaNotEnabled:
      return l10n.mfaResetMfaNotEnabled;
    case MfaResetFailureKind.noWitness:
      return l10n.mfaResetNoWitness;
    case MfaResetFailureKind.resetAlreadyPending:
      return l10n.mfaResetAlreadyPending;
    case MfaResetFailureKind.resetLimitReached:
      return l10n.mfaResetLimitReached;
    case MfaResetFailureKind.invalidOrExpiredToken:
      return l10n.mfaResetLinkExpired;
    case MfaResetFailureKind.invalidWitness:
      return attemptsRemaining == null
          ? l10n.mfaResetWitnessInvalid
          : l10n.mfaResetWitnessAttemptsLeft(attemptsRemaining);
    case MfaResetFailureKind.tooManyAttempts:
      return l10n.mfaResetWitnessTooMany;
    case MfaResetFailureKind.requestNotOpen:
      return l10n.mfaResetRequestNotOpen;
    case MfaResetFailureKind.roleNotAllowed:
      return l10n.mfaResetApproveRole;
    case MfaResetFailureKind.forbidden:
      return l10n.mfaResetApproveForbidden;
    case MfaResetFailureKind.unauthorized:
      return l10n.mfaSessionError;
    case MfaResetFailureKind.requestNotFound:
      return l10n.mfaResetRequestNotFound;
    case MfaResetFailureKind.witnessRequired:
      return l10n.mfaResetWitnessRequired;
    case MfaResetFailureKind.requestCancelled:
      return l10n.mfaResetRequestCancelled;
    case MfaResetFailureKind.requestExpired:
      return l10n.mfaResetRequestExpired;
    case MfaResetFailureKind.requestCompleted:
      return l10n.mfaResetRequestCompleted;
    case MfaResetFailureKind.windowOpen:
      return l10n.mfaResetWindowOpen;
    case MfaResetFailureKind.witnessDispatchFailed:
      return l10n.mfaResetWitnessDispatchFailed;
    case MfaResetFailureKind.resetUnavailable:
      return l10n.mfaResetUnavailable;
    case MfaResetFailureKind.rateLimited:
      return l10n.mfaTooManyAttempts;
    case MfaResetFailureKind.network:
      return l10n.mfaNetworkError;
    case MfaResetFailureKind.validation:
    case MfaResetFailureKind.malformed:
    case MfaResetFailureKind.unknown:
      return l10n.mfaRequestFailed;
  }
}
