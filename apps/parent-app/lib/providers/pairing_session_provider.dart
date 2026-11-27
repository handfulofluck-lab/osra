import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'clock_provider.dart';

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

/// Poll interval while Home is watching an unclaimed pairing code (`status: waiting`).
final pairingClaimPollIntervalProvider =
    Provider<Duration>((ref) => const Duration(seconds: 2));

/// Reads `GET /v1/devices/pair/:code/claim` for an active pairing code (A10).
///
/// While watched on Home and the code is still unclaimed (`status: waiting`),
/// schedules a bounded one-shot refresh after [pairingClaimPollIntervalProvider]
/// until a claim arrives (`pending`/`approved`/`paired`/`denied`), the server
/// answers `404`, the session expires, or Home unmounts.
final activePairingClaimProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, code) async {
  if (!RegExp(r'^\d{6}$').hasMatch(code)) return null;
  final session = ref.watch(activePairingSessionProvider);
  if (session != null &&
      session.code == code &&
      session.isExpiredAt(ref.read(clockProvider)())) {
    return null;
  }

  void scheduleNextPollIfUnexpired() {
    final active = ref.read(activePairingSessionProvider);
    if (active != null &&
        active.code == code &&
        active.isExpiredAt(ref.read(clockProvider)())) {
      return;
    }
    final interval = ref.read(pairingClaimPollIntervalProvider);
    if (interval <= Duration.zero) return;
    final timer = Timer(interval, ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }

  try {
    final res = await ref
        .watch(apiClientProvider)
        .raw
        .get('/v1/devices/pair/$code/claim');
    if (res.data is Map) {
      final data = Map<String, dynamic>.from(res.data as Map);
      if (data['status'] == 'waiting') {
        scheduleNextPollIfUnexpired();
      }
      return data;
    }
  } on DioException catch (e) {
    if (e.response?.statusCode == 404) {
      return null;
    }
    scheduleNextPollIfUnexpired();
  } catch (_) {
    // Unknown failure: treat as no pending claim without crashing Home.
  }
  return null;
});