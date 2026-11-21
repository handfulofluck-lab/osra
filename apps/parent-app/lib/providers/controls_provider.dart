import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/children/internet_state.dart';
import 'auth_provider.dart';

/// Optimistic pause-the-internet overrides keyed by childId, applied while the
/// pause/resume POST is in flight (Feature #11).
final _pauseOverridesProvider = StateProvider<Map<String, bool>>((ref) => const {});

class ChildInternetStatus {
  const ChildInternetStatus({this.action, this.deviceStatuses = const []});

  factory ChildInternetStatus.fromResponse(Object? response) {
    if (response is! Map) return const ChildInternetStatus();
    final request = response['internetRequest'];
    if (request is Map && (request['action'] == 'pause' || request['action'] == 'resume')) {
      final devices = request['devices'];
      return ChildInternetStatus(
        action: request['action'] as String,
        deviceStatuses: [
          if (devices is List)
            for (final device in devices)
              device is Map && device['status'] is String ? device['status'] as String : 'unknown',
        ],
      );
    }
    // Older staging servers carry the requested pause Boolean and no evidence of delivery.
    return ChildInternetStatus(action: response['paused'] == true ? 'pause' : null);
  }

  final String? action;
  final List<String> deviceStatuses;

  bool get paused => action == 'pause';
  bool get hasAcknowledgedDevice => deviceStatuses.contains('acked');
  InternetState get state => internetStateFor(action: action, deviceStatuses: deviceStatuses);
}

/// Reads the latest child-wide request and each device's result for that request.
final childInternetStatusProvider = FutureProvider.autoDispose.family<ChildInternetStatus, String>((ref, childId) async {
  final override = ref.watch(_pauseOverridesProvider)[childId];
  if (override != null) return ChildInternetStatus(action: override ? 'pause' : 'resume');
  final api = ref.watch(apiClientProvider);
  Timer? refresh;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    refresh?.cancel();
  });
  try {
    final res = await api.raw.get('/v1/controls/children/$childId/status');
    final status = ChildInternetStatus.fromResponse(res.data);
    if (!disposed && status.deviceStatuses.any((device) => device == 'pending' || device == 'delivered')) {
      // Refresh server expiry even when an offline handset cannot send an acknowledgement.
      refresh = Timer(const Duration(seconds: 15), ref.invalidateSelf);
    }
    return status;
  } on DioException catch (e) {
    if (e.response?.statusCode == 404) return const ChildInternetStatus();
    rethrow;
  }
});

/// The requested state determines which action the existing Overview button offers.
final internetPausedProvider = FutureProvider.autoDispose.family<bool, String>((ref, childId) async {
  return (await ref.watch(childInternetStatusProvider(childId).future)).paused;
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
  ref.invalidate(childInternetStatusProvider(childId));
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
