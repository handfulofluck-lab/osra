import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth_provider.dart';
import 'family_provider.dart';

const _unset = Object();

class SocialVoteRevisionRegistry {
  final _revisions = <String, int>{};

  int revisionOf(String eventId) => _revisions[eventId] ?? 0;

  int advance(String eventId) {
    final next = revisionOf(eventId) + 1;
    _revisions[eventId] = next;
    return next;
  }

  Map<String, int> snapshot() => Map.unmodifiable(_revisions);
}

final socialVoteRevisionRegistryProvider =
    Provider<SocialVoteRevisionRegistry>((ref) => SocialVoteRevisionRegistry());

@immutable
class SocialVoteState {
  final String? verdict;
  final String? parentDisplayName;
  final DateTime? firstVotedAt;
  final DateTime? lastChangedAt;
  final String? ownVerdict;
  final DateTime? ownFirstVotedAt;
  final DateTime? ownLastChangedAt;
  final bool isSaving;
  final bool needsRetry;
  final bool isUnavailable;

  const SocialVoteState({
    this.verdict,
    this.parentDisplayName,
    this.firstVotedAt,
    this.lastChangedAt,
    this.ownVerdict,
    this.ownFirstVotedAt,
    this.ownLastChangedAt,
    this.isSaving = false,
    this.needsRetry = false,
    this.isUnavailable = false,
  });

  SocialVoteState copyWith({
    Object? verdict = _unset,
    Object? parentDisplayName = _unset,
    Object? firstVotedAt = _unset,
    Object? lastChangedAt = _unset,
    Object? ownVerdict = _unset,
    Object? ownFirstVotedAt = _unset,
    Object? ownLastChangedAt = _unset,
    bool? isSaving,
    bool? needsRetry,
    bool? isUnavailable,
  }) {
    return SocialVoteState(
      verdict: identical(verdict, _unset) ? this.verdict : verdict as String?,
      parentDisplayName: identical(parentDisplayName, _unset)
          ? this.parentDisplayName
          : parentDisplayName as String?,
      firstVotedAt: identical(firstVotedAt, _unset)
          ? this.firstVotedAt
          : firstVotedAt as DateTime?,
      lastChangedAt: identical(lastChangedAt, _unset)
          ? this.lastChangedAt
          : lastChangedAt as DateTime?,
      ownVerdict: identical(ownVerdict, _unset)
          ? this.ownVerdict
          : ownVerdict as String?,
      ownFirstVotedAt: identical(ownFirstVotedAt, _unset)
          ? this.ownFirstVotedAt
          : ownFirstVotedAt as DateTime?,
      ownLastChangedAt: identical(ownLastChangedAt, _unset)
          ? this.ownLastChangedAt
          : ownLastChangedAt as DateTime?,
      isSaving: isSaving ?? this.isSaving,
      needsRetry: needsRetry ?? this.needsRetry,
      isUnavailable: isUnavailable ?? this.isUnavailable,
    );
  }
}

final socialVoteProvider =
    StateNotifierProvider.family<SocialVoteController, SocialVoteState, String>(
  (ref, eventId) {
    final controller = SocialVoteController(ref, eventId);
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (previous == null) return;
      if (previous.isAuthenticated != next.isAuthenticated ||
          previous.parent?.id != next.parent?.id) {
        controller.reset();
      }
    });
    return controller;
  },
);

class _OwnVoteSnapshot {
  final String? verdict;
  final DateTime? firstVotedAt;
  final DateTime? lastChangedAt;

  const _OwnVoteSnapshot({
    required this.verdict,
    required this.firstVotedAt,
    required this.lastChangedAt,
  });

  factory _OwnVoteSnapshot.fromState(SocialVoteState state) => _OwnVoteSnapshot(
        verdict: state.ownVerdict,
        firstVotedAt: state.ownFirstVotedAt,
        lastChangedAt: state.ownLastChangedAt,
      );
}

class SocialVoteController extends StateNotifier<SocialVoteState> {
  final Ref _ref;
  final String _eventId;
  int _revision;
  bool _disposed = false;
  bool _hasPendingOperation = false;
  String? _pendingVerdict;
  _OwnVoteSnapshot? _undoState;
  Future<void> _writeTail = Future<void>.value();

  SocialVoteController(Ref ref, String eventId)
      : _ref = ref,
        _eventId = eventId,
        _revision =
            ref.read(socialVoteRevisionRegistryProvider).revisionOf(eventId),
        super(const SocialVoteState());

  int get revision => _revision;

  int _advanceRevision() {
    _revision = _ref.read(socialVoteRevisionRegistryProvider).advance(_eventId);
    return _revision;
  }

  void reset() {
    _advanceRevision();
    _hasPendingOperation = false;
    _pendingVerdict = null;
    _undoState = null;
    if (!_disposed) state = const SocialVoteState();
  }

  void syncFromEvent(SocialConcernEvent event, [int? startedRevision]) {
    if (startedRevision != null && startedRevision != _revision) return;
    if (state.isSaving || state.needsRetry || state.isUnavailable) return;
    state = state.copyWith(
      verdict: event.latestFeedbackVerdict,
      parentDisplayName: event.latestFeedbackParentDisplayName,
      firstVotedAt: event.latestFeedbackFirstVotedAt,
      lastChangedAt: event.latestFeedbackLastChangedAt,
      ownVerdict: event.ownFeedbackVerdict,
      ownFirstVotedAt: event.ownFeedbackFirstVotedAt,
      ownLastChangedAt: event.ownFeedbackLastChangedAt,
      isSaving: false,
      needsRetry: false,
      isUnavailable: false,
    );
  }

  Future<void> vote(String verdict) {
    if (verdict != 'concerning' && verdict != 'not_concerning') {
      throw ArgumentError.value(verdict, 'verdict');
    }
    if (state.ownVerdict == verdict && !state.needsRetry) {
      return Future<void>.value();
    }
    return _mutate(verdict);
  }

  Future<void> withdraw() {
    if (state.ownVerdict == null) return Future<void>.value();
    return _mutate(null);
  }

  Future<void> undo() {
    final previous = _undoState;
    if (previous == null) return Future<void>.value();
    return _mutate(previous.verdict, previous: previous);
  }

  Future<void> retry() {
    if (!state.needsRetry || !_hasPendingOperation) {
      return Future<void>.value();
    }
    return _mutate(_pendingVerdict, recordUndo: false);
  }

  String? get _currentParentDisplayName {
    final name =
        _ref.read(familyProvider).valueOrNull?.parent.displayName.trim();
    return name == null || name.isEmpty ? null : name;
  }

  Future<void> _mutate(
    String? verdict, {
    _OwnVoteSnapshot? previous,
    bool recordUndo = true,
  }) {
    if (recordUndo) _undoState = _OwnVoteSnapshot.fromState(state);
    final now = DateTime.now().toUtc();
    _pendingVerdict = verdict;
    _hasPendingOperation = true;
    final revision = _advanceRevision();
    final ownFirstVotedAt = verdict == null
        ? null
        : previous?.firstVotedAt ??
            (state.ownVerdict == null ? now : state.ownFirstVotedAt);
    final ownLastChangedAt =
        verdict == null ? null : previous?.lastChangedAt ?? now;
    state = state.copyWith(
      verdict: verdict ?? state.verdict,
      parentDisplayName:
          verdict == null ? state.parentDisplayName : _currentParentDisplayName,
      firstVotedAt: verdict == null ? state.firstVotedAt : ownFirstVotedAt,
      lastChangedAt: verdict == null ? state.lastChangedAt : ownLastChangedAt,
      ownVerdict: verdict,
      ownFirstVotedAt: ownFirstVotedAt,
      ownLastChangedAt: ownLastChangedAt,
      isSaving: true,
      needsRetry: false,
      isUnavailable: false,
    );

    final operation = _writeTail.then((_) => _write(verdict, revision));
    _writeTail = operation;
    return operation;
  }

  Future<void> _write(String? verdict, int revision) async {
    if (_disposed || revision != _revision) return;
    try {
      final api = _ref.read(apiClientProvider).raw;
      final path = '/v1/social/events/$_eventId/feedback';
      final response = verdict == null
          ? await api.delete<dynamic>(path)
          : await api.post<dynamic>(path, data: {'verdict': verdict});
      if (_disposed || revision != _revision) return;
      final data = response.data;
      final body = data is Map ? data : const <String, dynamic>{};
      final rawOwn = body['feedback'];
      final rawLatest =
          body.containsKey('latestFeedback') ? body['latestFeedback'] : rawOwn;
      final own = rawOwn is Map ? rawOwn : null;
      final latest = rawLatest is Map ? rawLatest : null;
      final latestParent = latest?['parentDisplayName']?.toString().trim();
      state = state.copyWith(
        verdict: latest?['verdict']?.toString(),
        parentDisplayName:
            latestParent == null || latestParent.isEmpty ? null : latestParent,
        firstVotedAt: latest == null
            ? null
            : DateTime.tryParse(latest['firstVotedAt']?.toString() ?? '') ??
                state.firstVotedAt,
        lastChangedAt: latest == null
            ? null
            : DateTime.tryParse(latest['lastChangedAt']?.toString() ?? '') ??
                state.lastChangedAt,
        ownVerdict: own?['verdict']?.toString(),
        ownFirstVotedAt: own == null
            ? null
            : DateTime.tryParse(own['firstVotedAt']?.toString() ?? '') ??
                state.ownFirstVotedAt,
        ownLastChangedAt: own == null
            ? null
            : DateTime.tryParse(own['lastChangedAt']?.toString() ?? '') ??
                state.ownLastChangedAt,
        isSaving: false,
        needsRetry: false,
        isUnavailable: false,
      );
    } catch (error) {
      if (_disposed || revision != _revision) return;
      final status = error is DioException ? error.response?.statusCode : null;
      final unavailable = status == 403 || status == 404;
      state = state.copyWith(
        isSaving: false,
        needsRetry: !unavailable,
        isUnavailable: unavailable,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
