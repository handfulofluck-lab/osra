import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth_provider.dart';

/// Parses an `{items, meta}` envelope (or a bare list) into model instances.
List<T> _itemsOf<T>(dynamic data, T Function(Map<String, dynamic>) fromJson) {
  final raw = data is Map ? data['items'] : data;
  if (raw is! List) return const [];
  return [for (final e in raw) if (e is Map) fromJson(Map<String, dynamic>.from(e))];
}

/// Flagged search queries listing for one child
/// (`GET /v1/content/searches?childId=&limit=50`).
final searchEventsProvider = FutureProvider.family<List<SearchEventItem>, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/content/searches', queryParameters: {'childId': childId, 'limit': 50});
  return _itemsOf(res.data, SearchEventItem.fromJson);
});
