import 'package:dio/dio.dart';

import 'client.dart';
import 'models.dart';

/// The refusals the six `/v1/auth/mfa/reset` routes can return, reduced to
/// exactly the distinctions the API makes.
///
/// Several refusals are deliberately indistinguishable server-side and stay
/// one kind here: `request` answers `401 invalid_credentials` for an unknown
/// address and a wrong password alike (the `/login` refusal), `witness` answers
/// `401 invalid_witness` for an unknown request, an expired code and a wrong
/// code alike, and `complete` answers `404 request_not_found` for "no such
/// request" and "another parent's request" alike. The UI must not split them
/// further.
enum MfaResetFailureKind {
  /// 401 `invalid_credentials` — `/request` and `/complete`, the `/login` refusal.
  invalidCredentials,

  /// 409 `mfa_not_enabled` — there is no second factor to reset.
  mfaNotEnabled,

  /// 409 `no_witness` — no paired child device and no other owner/co-parent
  /// (ADR-0031 decision 6). Nothing was stored.
  noWitness,

  /// 409 `reset_already_pending` — this parent's request already passed its
  /// witness and holds the 72-hour window.
  resetAlreadyPending,

  /// 429 `reset_limit_reached` — three requests in 30 days.
  resetLimitReached,

  /// 401 `invalid_or_expired_token` — the mailbox/cancel link was spent,
  /// expired, forged or signed for another purpose. One answer by design.
  invalidOrExpiredToken,

  /// 401 `invalid_witness` — unknown request id, expired code or wrong code.
  /// When the API sends `attemptsRemaining`, [MfaResetFailure.attemptsRemaining]
  /// carries it; that is server information, not an invented distinction.
  invalidWitness,

  /// 401 `too_many_attempts` — the fifth wrong code ended the request.
  tooManyAttempts,

  /// 409 `request_not_open` — the request already left the state the action
  /// needed (passed, cancelled or expired).
  requestNotOpen,

  /// 403 `role_not_allowed` — a `guardian` cannot approve or cancel a reset.
  roleNotAllowed,

  /// 403 `forbidden` — another family's request, or the subject's own.
  forbidden,

  /// 401 `unauthorized` / `session_revoked` — the caller's session is gone.
  unauthorized,

  /// 404 `request_not_found` / `not_found` / `parent_not_found`.
  requestNotFound,

  /// 409 `witness_required` — `complete` before the witness step.
  witnessRequired,

  /// 409 `request_cancelled` — cancelled by sign-in, link or another parent.
  requestCancelled,

  /// 409 `request_expired` — a deadline passed.
  requestExpired,

  /// 409 `request_completed` — `complete` ran already.
  requestCompleted,

  /// 409 `window_open` — `complete` before `windowEndsAt`; nothing changed.
  windowOpen,

  /// 503 `witness_dispatch_failed` — the mailbox step was spent but no code
  /// could be queued; the request ends at its 24-hour deadline.
  witnessDispatchFailed,

  /// 503 `reset_unavailable` — the mailbox-link store is unreachable.
  resetUnavailable,

  /// 429 without a route-specific code — the auth rate limit.
  rateLimited,

  /// 400 with a validation body.
  validation,

  /// The request never reached the server.
  network,

  /// A 2xx whose body was not the shape the contract promises.
  malformed,

  /// Anything else, reported without inventing a cause.
  unknown,
}

/// A typed failure from the reset routes; screens translate [kind] and never
/// show server text.
class MfaResetFailure implements Exception {
  final MfaResetFailureKind kind;
  final int? statusCode;

  /// Present only when the API said so (`invalid_witness` after a wrong code).
  final int? attemptsRemaining;

  const MfaResetFailure(this.kind, {this.statusCode, this.attemptsRemaining});

  @override
  String toString() =>
      'MfaResetFailure(${kind.name}, status: $statusCode, attemptsRemaining: $attemptsRemaining)';
}

/// Thin client over the six ADR-0031 reset routes.
///
/// `request`, `witness`, `confirm` and the link form of `cancel` are
/// unauthenticated by construction: the parent being reset cannot hold a
/// session (`/login` needs the authenticator they lost). `approve` and the
/// session form of `cancel` use the stored session of another owner/co-parent.
///
/// There is no read route: the API exposes no way to ask for a request's
/// current state (`docs/SPEC.md`: the read-only audit route of ADR-0031
/// decision 8 is not built). Nothing here pretends otherwise.
class MfaResetApi {
  MfaResetApi(this._client);

  final ApiClient _client;

  /// Password + mailbox step. Answers nothing about the mailbox beyond its
  /// deadline; a witness is never told before the link is clicked.
  Future<MfaResetRequestResult> request({
    required String email,
    required String password,
  }) async {
    final data = await _post('/v1/auth/mfa/reset/request', {
      'email': email,
      'password': password,
    });
    final result = MfaResetRequestResult.fromJson(data);
    if (result.requestId.isEmpty) throw const MfaResetFailure(MfaResetFailureKind.malformed);
    return result;
  }

  /// The mailbox link, consumed by the web page the email points at. The app
  /// does not call this today; it is here so the contract has one home.
  Future<MfaResetConfirmResult> confirm(String token) async {
    final data = await _post('/v1/auth/mfa/reset/confirm', {'token': token});
    final result = MfaResetConfirmResult.fromJson(data);
    if (result.requestId.isEmpty || result.witness.isEmpty) {
      throw const MfaResetFailure(MfaResetFailureKind.malformed);
    }
    return result;
  }

  /// The 8-digit code shown on a paired child device.
  Future<MfaResetWitnessAccepted> submitWitness({
    required String requestId,
    required String code,
  }) async {
    final data = await _post('/v1/auth/mfa/reset/witness', {
      'requestId': requestId,
      'code': code,
    });
    return _accepted(data);
  }

  /// Another `owner` or `co-parent` approves from their own signed-in app.
  Future<MfaResetWitnessAccepted> approve(String requestId) async {
    final data = await _post('/v1/auth/mfa/reset/approve', {'requestId': requestId});
    return _accepted(data);
  }

  /// Cancel by the emailed link (no sign-in) or by another owner/co-parent's
  /// session. Cancelling is idempotent.
  Future<MfaResetCancelResult> cancel({String? token, String? requestId}) async {
    if ((token == null || token.isEmpty) == (requestId == null || requestId.isEmpty)) {
      throw ArgumentError('cancel takes exactly one of token or requestId');
    }
    final data = await _post('/v1/auth/mfa/reset/cancel', {
      if (token != null && token.isNotEmpty) 'token': token,
      if (requestId != null && requestId.isNotEmpty) 'requestId': requestId,
    });
    return MfaResetCancelResult.fromJson(data);
  }

  /// After `windowEndsAt`: ADR-0023's recovery sequence, answered with the
  /// 15-minute `purpose:"mfa_recovery"` token.
  Future<MfaResetCompleteResult> complete({
    required String email,
    required String password,
    required String requestId,
  }) async {
    final data = await _post('/v1/auth/mfa/reset/complete', {
      'email': email,
      'password': password,
      'requestId': requestId,
    });
    final result = MfaResetCompleteResult.fromJson(data);
    if (result.recoveryToken.isEmpty) throw const MfaResetFailure(MfaResetFailureKind.malformed);
    return result;
  }

  static MfaResetWitnessAccepted _accepted(Map<String, dynamic> data) {
    final accepted = MfaResetWitnessAccepted.fromJson(data);
    if (accepted.state != 'witness_passed' || accepted.windowEndsAt == null) {
      throw const MfaResetFailure(MfaResetFailureKind.malformed);
    }
    return accepted;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    try {
      final res = await _client.raw.post(path, data: body);
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const MfaResetFailure(MfaResetFailureKind.malformed);
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  static MfaResetFailure _failure(DioException e) {
    final status = e.response?.statusCode;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const MfaResetFailure(MfaResetFailureKind.network);
      default:
        break;
    }
    final body = e.response?.data;
    final error = body is Map ? body['error'] : null;
    final rawAttempts = body is Map ? body['attemptsRemaining'] : null;
    final attempts =
        rawAttempts is num ? rawAttempts.toInt() : (rawAttempts is String ? int.tryParse(rawAttempts) : null);
    switch (error) {
      case 'invalid_credentials':
        return MfaResetFailure(MfaResetFailureKind.invalidCredentials, statusCode: status);
      case 'mfa_not_enabled':
        return MfaResetFailure(MfaResetFailureKind.mfaNotEnabled, statusCode: status);
      case 'no_witness':
        return MfaResetFailure(MfaResetFailureKind.noWitness, statusCode: status);
      case 'reset_already_pending':
        return MfaResetFailure(MfaResetFailureKind.resetAlreadyPending, statusCode: status);
      case 'reset_limit_reached':
        return MfaResetFailure(MfaResetFailureKind.resetLimitReached, statusCode: status);
      case 'invalid_or_expired_token':
        return MfaResetFailure(MfaResetFailureKind.invalidOrExpiredToken, statusCode: status);
      case 'invalid_witness':
        return MfaResetFailure(
          MfaResetFailureKind.invalidWitness,
          statusCode: status,
          attemptsRemaining: attempts,
        );
      case 'too_many_attempts':
        return MfaResetFailure(MfaResetFailureKind.tooManyAttempts, statusCode: status);
      case 'request_not_open':
        return MfaResetFailure(MfaResetFailureKind.requestNotOpen, statusCode: status);
      case 'role_not_allowed':
        return MfaResetFailure(MfaResetFailureKind.roleNotAllowed, statusCode: status);
      case 'forbidden':
        return MfaResetFailure(MfaResetFailureKind.forbidden, statusCode: status);
      case 'unauthorized':
      case 'session_revoked':
        return MfaResetFailure(MfaResetFailureKind.unauthorized, statusCode: status);
      case 'request_not_found':
      case 'not_found':
      case 'parent_not_found':
        return MfaResetFailure(MfaResetFailureKind.requestNotFound, statusCode: status);
      case 'witness_required':
        return MfaResetFailure(MfaResetFailureKind.witnessRequired, statusCode: status);
      case 'request_cancelled':
        return MfaResetFailure(MfaResetFailureKind.requestCancelled, statusCode: status);
      case 'request_expired':
        return MfaResetFailure(MfaResetFailureKind.requestExpired, statusCode: status);
      case 'request_completed':
        return MfaResetFailure(MfaResetFailureKind.requestCompleted, statusCode: status);
      case 'window_open':
        return MfaResetFailure(MfaResetFailureKind.windowOpen, statusCode: status);
      case 'witness_dispatch_failed':
        return MfaResetFailure(MfaResetFailureKind.witnessDispatchFailed, statusCode: status);
      case 'reset_unavailable':
        return MfaResetFailure(MfaResetFailureKind.resetUnavailable, statusCode: status);
    }
    if (status == 429) return MfaResetFailure(MfaResetFailureKind.rateLimited, statusCode: status);
    if (status == 400) return MfaResetFailure(MfaResetFailureKind.validation, statusCode: status);
    return MfaResetFailure(MfaResetFailureKind.unknown, statusCode: status);
  }
}
