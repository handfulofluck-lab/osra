import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth_provider.dart';
import 'family_provider.dart';

const _unset = Object();

@immutable
class SocialVoteState {
  final String? verdict;
  final String? parentDisplayName;
  final DateTime? firstVotedAt;
  final DateTime? lastChangedAt;
  final bool isSaving;
  final bool needsRetry;
  final bool isUnavailable;

  const SocialVoteState({
    this.verdict,
    this.parentDisplayName,
    this.firstVotedAt,
    this.lastChangedAt,
    this.isSaving = false,
    this.needsRetry = false,
    this.isUnavailable = false,
  });

  SocialVoteState copyWith({
    Object? verdict = _unset,
    Object? parentDisplayName = _unset,
    Object? firstVotedAt = _unset,
    Object? lastChangedAt = _unset,
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

class SocialVoteController extends StateNotifier<SocialVoteState> {
  final Ref _ref;
  final String _eventId;
  int _revision = 0;
  bool _disposed = false;
  bool _hasPendingOperation = false;
  String? _pendingVerdict;
  SocialVoteState? _undoState;
  Future<void> _writeTail = Future<void>.value();

  SocialVoteController(this._ref, this._eventId)
      : super(const SocialVoteState());

  void reset() {
    _revision++;
    _hasPendingOperation = false;
    _pendingVerdict = null;
    _undoState = null;
    if (!_disposed) state = const SocialVoteState();
  }

  void syncFromEvent(SocialConcernEvent event) {
    if (state.isSaving || state.needsRetry || state.isUnavailable) return;
    state = state.copyWith(
      verdict: event.latestFeedbackVerdict,
      parentDisplayName: event.latestFeedbackParentDisplayName,
      firstVotedAt: event.latestFeedbackFirstVotedAt,
      lastChangedAt: event.latestFeedbackLastChangedAt,
      isSaving: false,
      needsRetry: false,
      isUnavailable: false,
    );
  }

  Future<void> vote(String verdict) {
    if (verdict != 'concerning' && verdict != 'not_concerning') {
      throw ArgumentError.value(verdict, 'verdict');
    }
    if (state.verdict == verdict && !state.needsRetry) {
      return Future<void>.value();
    }
    return _mutate(verdict);
  }

  Future<void> withdraw() => _mutate(null);

  Future<void> undo() {
    final previous = _undoState;
    if (previous == null) return Future<void>.value();
    final previousParent = previous.parentDisplayName;
    final canRestore = previous.verdict != null &&
        previousParent != null &&
        previousParent == _currentParentDisplayName;
    return _mutate(
      canRestore ? previous.verdict : null,
      previous: canRestore ? previous : null,
    );
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
    SocialVoteState? previous,
    bool recordUndo = true,
  }) {
    if (recordUndo) _undoState = state;
    final targetState = previous;
    final now = DateTime.now().toUtc();
    _pendingVerdict = verdict;
    _hasPendingOperation = true;
    final revision = ++_revision;
    state = state.copyWith(
      verdict: verdict,
      parentDisplayName: verdict == null
          ? null
          : targetState?.parentDisplayName ?? _currentParentDisplayName,
      firstVotedAt: verdict == null ? null : targetState?.firstVotedAt ?? now,
      lastChangedAt: verdict == null ? null : targetState?.lastChangedAt ?? now,
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
      final rawFeedback = body.containsKey('feedback')
          ? body['feedback']
          : body['latestFeedback'];
      if (rawFeedback is Map) {
        final parentName = rawFeedback['parentDisplayName']?.toString().trim();
        state = state.copyWith(
          verdict: rawFeedback['verdict']?.toString(),
          parentDisplayName: parentName == null || parentName.isEmpty
              ? state.parentDisplayName
              : parentName,
          firstVotedAt: DateTime.tryParse(
                rawFeedback['firstVotedAt']?.toString() ?? '',
              ) ??
              state.firstVotedAt,
          lastChangedAt: DateTime.tryParse(
                rawFeedback['lastChangedAt']?.toString() ?? '',
              ) ??
              state.lastChangedAt,
          isSaving: false,
          needsRetry: false,
          isUnavailable: false,
        );
      } else {
        state = state.copyWith(
          isSaving: false,
          needsRetry: false,
          isUnavailable: false,
        );
      }
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
