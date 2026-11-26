import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';

/// Active pairing code generated in this session so Home ('Needs you', A10) can
/// surface a pending phone claim when the parent navigates away from P-05.
@immutable
class ActivePairingSession {
  final String code;
  final String childId;
  final DateTime expiresAt;

  const ActivePairingSession({
    required this.code,
    required this.childId,
    required this.expiresAt,
  });

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now);
}

final activePairingSessionProvider =
    StateProvider<ActivePairingSession?>((ref) => null);

/// Reads `GET /v1/devices/pair/:code/claim` for an active pairing code (A10).
final activePairingClaimProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, code) async {
  if (!RegExp(r'^\d{6}$').hasMatch(code)) return null;
  try {
    final res =
        await ref.watch(apiClientProvider).raw.get('/v1/devices/pair/$code/claim');
    if (res.data is Map) {
      return Map<String, dynamic>.from(res.data as Map);
    }
  } catch (_) {
    // Expired or unknown code answers 404; treat as no pending claim.
  }
  return null;
});
