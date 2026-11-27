import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth_provider.dart';
import 'social_vote_provider.dart';

/// Parses an `{items, meta}` envelope (or a bare list) into model instances.
List<T> _itemsOf<T>(dynamic data, T Function(Map<String, dynamic>) fromJson) {
  final raw = data is Map ? data['items'] : data;
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map) fromJson(Map<String, dynamic>.from(e))
  ];
}

/// Decrypted social-concern vault for one child
/// (`GET /v1/social/events?childId&limit=`, features #2/#24).
final socialEventsProvider =
    FutureProvider.family<List<SocialConcernEvent>, String>(
        (ref, childId) => _fetchSocialEvents(ref, childId));

/// The alert's exact preview, under the same child and Social read permissions.
final socialConcernProvider = FutureProvider.autoDispose
    .family<List<SocialConcernEvent>, ({String childId, String eventId})>(
        (ref, target) =>
            _fetchSocialEvents(ref, target.childId, eventId: target.eventId));

Future<List<SocialConcernEvent>> _fetchSocialEvents(Ref ref, String childId,
    {String? eventId}) async {
  final api = ref.watch(apiClientProvider);
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  final startedRevisions =
      ref.read(socialVoteRevisionRegistryProvider).snapshot();
  final res = await api.raw
      .get('/v1/social/events', cancelToken: cancelToken, queryParameters: {
    'childId': childId,
    'limit': eventId == null ? 50 : 1,
    if (eventId != null) 'eventId': eventId,
  });
  if (cancelToken.isCancelled) return const [];
  final events = _itemsOf(res.data, SocialConcernEvent.fromJson)
      .where((event) => eventId == null || event.id == eventId)
      .toList();
  for (final event in events) {
    ref
        .read(socialVoteProvider(event.id).notifier)
        .syncFromEvent(event, startedRevisions[event.id] ?? 0);
  }
  return events;
}

/// Merged call, SMS and lock-period timeline for one child, newest first (features #6, #830):
/// fetches `GET /v1/reports/activity` once per type and sorts by `ts`.
final activityProvider =
    FutureProvider.family<List<ActivityEvent>, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final calls = await api.raw.get('/v1/reports/activity',
      queryParameters: {'childId': childId, 'type': 'call', 'limit': 100});
  final sms = await api.raw.get('/v1/reports/activity',
      queryParameters: {'childId': childId, 'type': 'sms', 'limit': 100});
  // #830: one row per lock period, with the number of times the child met the overlay.
  final locks = await api.raw.get('/v1/reports/activity', queryParameters: {
    'childId': childId,
    'type': 'lock_period',
    'limit': 100
  });
  final items = [
    ..._itemsOf(calls.data, ActivityEvent.fromJson),
    ..._itemsOf(sms.data, ActivityEvent.fromJson),
    ..._itemsOf(locks.data, ActivityEvent.fromJson),
  ];
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  items.sort((a, b) => (b.ts ?? epoch).compareTo(a.ts ?? epoch));
  return items;
});
