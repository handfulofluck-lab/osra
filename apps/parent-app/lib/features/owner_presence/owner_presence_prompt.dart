import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/owner_presence.dart';

/// Issue #742: the last refused mutation, so the refusal screen can offer the settings path and then repeat the
/// same save once the parent has set a lock.
///
/// [pending] is the request the interceptor stopped. It is never logged and never stored anywhere else: it can
/// carry a family setting the parent typed, and it exists only until the screen is closed.
class OwnerPresencePrompt {
  const OwnerPresencePrompt({required this.result, required this.pending});

  final OwnerPresence result;
  final RequestOptions pending;
}

/// Null when nothing is waiting. Set by `apiClientProvider` when the gate refuses with `unavailable`; cleared by
/// the screen when it closes, whatever the outcome.
final ownerPresencePromptProvider = StateProvider<OwnerPresencePrompt?>((ref) => null);
