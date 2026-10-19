import 'package:dio/dio.dart';

import 'client.dart';
import 'models.dart';

/// The failures the MFA routes can produce, reduced to what the API actually
/// tells us. `/mfa/recover` deliberately answers `401 invalid_recovery` for an
/// unknown address, a wrong password, a spent code and an account without MFA,
/// so the UI must not claim to know which one it was.
enum MfaFailureKind {
  /// 401 `unauthorized` / `session_revoked`, or an expired recovery token.
  unauthorized,

  /// 401 `reauth_required` — the password or current TOTP did not match.
  reauthRequired,

  /// 401 `invalid_code` — a valid-shaped code from the wrong time step.
  invalidCode,

  /// 400 `mfa_not_enrolled` — there is no secret to verify.
  mfaNotEnrolled,

  /// 401 `invalid_recovery` — the deliberately indistinguishable recovery failure.
  invalidRecovery,

  /// 429 — the auth rate limit.
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

/// A typed failure from the MFA routes; screens translate [kind] rather than
/// showing server text.
class MfaFailure implements Exception {
  final MfaFailureKind kind;
  final int? statusCode;

  const MfaFailure(this.kind, {this.statusCode});

  @override
  String toString() => 'MfaFailure(${kind.name}, status: $statusCode)';
}

/// Thin client over the four ADR-0023 MFA routes.
///
/// Every method accepts an optional [bearerToken]. Recovery passes the
/// purpose-scoped token returned by `/mfa/recover`; it is sent as the request's
/// own `Authorization` header (never as the stored session) and is accepted by
/// `/mfa/enroll` and `/mfa/verify` only.
class MfaApi {
  MfaApi(this._client);

  final ApiClient _client;

  Future<MfaEnrollment> enroll({String? password, String? code, String? bearerToken}) async {
    final data = await _post(
      '/v1/auth/mfa/enroll',
      {
        if (password != null && password.isNotEmpty) 'password': password,
        if (code != null && code.isNotEmpty) 'code': code,
      },
      bearerToken: bearerToken,
    );
    final enrollment = MfaEnrollment.fromJson(data);
    if (enrollment.secret.isEmpty || enrollment.otpauthUrl.isEmpty) {
      throw const MfaFailure(MfaFailureKind.malformed);
    }
    return enrollment;
  }

  /// Verifies the six-digit code and enables MFA. The returned batch is the
  /// only time the plaintext recovery codes exist; a failed call returns no
  /// codes and leaves MFA unchanged.
  Future<RecoveryCodeBatch> verify(String code, {String? bearerToken}) async {
    final data = await _post(
      '/v1/auth/mfa/verify',
      {'code': code},
      bearerToken: bearerToken,
    );
    return RecoveryCodeBatch.fromJson(data);
  }

  /// Issues a replacement batch (generation and regeneration are the same
  /// operation). Replacing an existing list invalidates it, so the API requires
  /// the #139 proof: the account password or a current authenticator code.
  Future<RecoveryCodeBatch> regenerate({String? password, String? code}) async {
    final data = await _post('/v1/auth/mfa/recovery-codes', {
      if (password != null && password.isNotEmpty) 'password': password,
      if (code != null && code.isNotEmpty) 'code': code,
    });
    return RecoveryCodeBatch.fromJson(data);
  }

  /// Spends one unused recovery code and returns the 15-minute purpose-scoped
  /// token. A 401 is always the same `invalid_recovery`, by design.
  Future<String> recover({
    required String email,
    required String password,
    required String code,
  }) async {
    final data = await _post('/v1/auth/mfa/recover', {
      'email': email,
      'password': password,
      'code': code,
    });
    final token = data['recoveryToken'];
    if (token is! String || token.isEmpty) {
      throw const MfaFailure(MfaFailureKind.malformed);
    }
    return token;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) async {
    try {
      final res = await _client.raw.post(
        path,
        data: body,
        options: bearerToken == null || bearerToken.isEmpty
            ? null
            // The header is set here as well as in the client interceptor so a
            // test double that replaces the Dio still sees the scoped token.
            : Options(
                headers: {'Authorization': 'Bearer $bearerToken'},
                extra: {'authToken': bearerToken},
              ),
      );
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const MfaFailure(MfaFailureKind.malformed);
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  static MfaFailure _failure(DioException e) {
    final status = e.response?.statusCode;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const MfaFailure(MfaFailureKind.network);
      default:
        break;
    }
    if (status == 429) {
      return const MfaFailure(MfaFailureKind.rateLimited, statusCode: 429);
    }
    final error = e.response?.data is Map ? (e.response!.data as Map)['error'] : null;
    switch (error) {
      case 'reauth_required':
        return MfaFailure(MfaFailureKind.reauthRequired, statusCode: status);
      case 'invalid_code':
        return MfaFailure(MfaFailureKind.invalidCode, statusCode: status);
      case 'mfa_not_enrolled':
        return MfaFailure(MfaFailureKind.mfaNotEnrolled, statusCode: status);
      case 'invalid_recovery':
        return MfaFailure(MfaFailureKind.invalidRecovery, statusCode: status);
      case 'unauthorized':
      case 'session_revoked':
        return MfaFailure(MfaFailureKind.unauthorized, statusCode: status);
    }
    if (status == 400) {
      return MfaFailure(MfaFailureKind.validation, statusCode: status);
    }
    return MfaFailure(MfaFailureKind.unknown, statusCode: status);
  }
}
