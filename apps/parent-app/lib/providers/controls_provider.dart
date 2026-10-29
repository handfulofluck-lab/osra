import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';

/// Optimistic pause-the-internet overrides keyed by childId, applied while the
/// pause/resume POST is in flight (Feature #11).
final _pauseOverridesProvider = StateProvider<Map<String, bool>>((ref) => const {});

/// Pause-the-internet status for one child (`GET /v1/controls/children/:id/status`).
/// A 404 (controls never configured for the child) means "not paused".
final internetPausedProvider = FutureProvider.family<bool, String>((ref, childId) async {
  final override = ref.watch(_pauseOverridesProvider)[childId];
  if (override != null) return override;
  final api = ref.watch(apiClientProvider);
  try {
    final res = await api.raw.get('/v1/controls/children/$childId/status');
    final data = res.data;
    return data is Map && data['paused'] == true;
  } on DioException catch (e) {
    if (e.response?.statusCode == 404) return false;
    rethrow;
  }
});

/// Queues `pause_internet` for every device of [childId]; the pill flips
/// optimistically and reverts when the POST fails.
Future<void> pauseInternet(WidgetRef ref, String childId) => _setPaused(ref, childId, true);

/// Queues `resume_internet` for every device of [childId]; same optimistic
/// semantics as [pauseInternet].
Future<void> resumeInternet(WidgetRef ref, String childId) => _setPaused(ref, childId, false);

/// Posts the pause/resume endpoint, flipping [internetPausedProvider]
/// optimistically and reverting to the server value on failure.
Future<void> _setPaused(WidgetRef ref, String childId, bool paused) async {
  final overrides = ref.read(_pauseOverridesProvider.notifier);
  overrides.update((m) => {...m, childId: paused});
  try {
    await ref.read(apiClientProvider).raw.post('/v1/controls/children/$childId/${paused ? 'pause' : 'resume'}');
  } catch (e) {
    overrides.update((m) => {...m}..remove(childId));
    // #437 A2: a refused write keeps its shape so the screen can say why.
    if (e is DioException) throw ControlsRefusal(e);
    rethrow;
  }
  overrides.update((m) => {...m}..remove(childId));
  ref.invalidate(internetPausedProvider(childId));
}

/// Issue #437 A2: a pause/resume the server refused, with the original exception intact.
///
/// The provider used to `rethrow` and every caller then did `commandFailed('$e')` — which stringifies a
/// `DioException` and loses the very thing the screen needs: the status and the body's `error`. A typed
/// wrapper keeps the contract small while letting the caller map one refusal, one sentence
/// (`readErrorText`), and leave everything else as it was.
class ControlsRefusal implements Exception {
  final DioException error;
  const ControlsRefusal(this.error);

  @override
  String toString() => 'ControlsRefusal(${error.response?.statusCode})';
}
