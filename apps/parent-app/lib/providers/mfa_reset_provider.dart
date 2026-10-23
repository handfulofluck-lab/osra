import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/mfa_reset_api.dart';
import '../api/mfa_reset_store.dart';
import '../api/models.dart';
import 'mfa_provider.dart';

/// The request id and address the app keeps between launches. Never a
/// password: [MfaResetStore] has no key for one.
final mfaResetStoreProvider = Provider<MfaResetStore>((ref) => const MfaResetStore());

/// The family's requests that still need a witness (`GET
/// /v1/auth/mfa/reset/pending`).
///
/// Watched by the dashboard and the MFA settings screen when a signed-in
/// owner/co-parent opens them. Every failure is an empty list, deliberately:
/// a `guardian` gets `403 role_not_allowed` and must see nothing rather than an
/// error page, and the prompt is an affordance, not a screen that can be
/// blocked. A network failure therefore hides the prompt; the approval screen
/// itself still reports its own failures when the parent acts.
final mfaResetPendingProvider =
    FutureProvider.autoDispose<List<MfaResetPendingRequest>>((ref) async {
  try {
    return await ref.watch(mfaResetApiProvider).pending();
  } on MfaResetFailure {
    return const <MfaResetPendingRequest>[];
  } catch (_) {
    return const <MfaResetPendingRequest>[];
  }
});
