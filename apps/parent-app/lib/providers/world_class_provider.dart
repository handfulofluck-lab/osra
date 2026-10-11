import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'auth_provider.dart';

/// Composite key for [reportSummaryProvider]: child + day range.
typedef ReportQuery = ({String childId, int days});

/// Aggregate report summary for one child and day range (feature #4,
/// `GET /v1/reports/summary?childId&days=`).
final reportSummaryProvider = FutureProvider.family<ReportSummary, ReportQuery>((ref, query) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/reports/summary', queryParameters: {
    'childId': query.childId,
    'days': query.days,
  });
  return ReportSummary.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Weekly wellbeing score for one child (feature #28, `GET /v1/reports/wellbeing/:childId`).
/// The server computes the current 7-day window when no `week` is passed.
final wellbeingProvider = FutureProvider.family<WellbeingScore, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/reports/wellbeing/$childId');
  return WellbeingScore.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Digest notification preferences (feature #5, `GET /v1/digests/prefs`).
final digestPrefsProvider = FutureProvider<DigestPrefs>((ref) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/digests/prefs');
  return DigestPrefs.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Curated insight for one app (feature #12, `GET /v1/insights/apps?packageId=`).
/// A 404 (app not in the curated DB) resolves to null so the sheet can show
/// the 'No insights' state instead of an error.
final appInsightsProvider = FutureProvider.family<AppInsight?, String>((ref, packageId) async {
  final api = ref.watch(apiClientProvider);
  try {
    final res = await api.raw.get('/v1/insights/apps', queryParameters: {'packageId': packageId});
    return AppInsight.fromJson(Map<String, dynamic>.from(res.data as Map));
  } on DioException catch (e) {
    if (e.response?.statusCode == 404) return null;
    rethrow;
  }
});

/// Latest live-activity snapshot per child (feature #29). `wsProvider`
/// updates this in place on every `live_activity` event; the dashboard chip
/// hides entries older than two minutes ([LiveActivity.isFresh]).
final liveActivityProvider = StateProvider<Map<String, LiveActivity>>((ref) => const {});

/// Today's location history for one child (feature #15,
/// `GET /v1/location/:childId/history?from=<local midnight>&to=<now>`).
/// Pings arrive newest-first from some agents, so they are sorted ascending.
final locationHistoryProvider = FutureProvider.family<List<LocationPing>, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final now = DateTime.now();
  final from = DateTime(now.year, now.month, now.day);
  final res = await api.raw.get('/v1/location/$childId/history', queryParameters: {
    'from': from.toIso8601String(),
    'to': now.toIso8601String(),
  });
  final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
  final pings = <LocationPing>[
    for (final p in (data['pings'] as List? ?? const []))
      LocationPing(
        deviceId: '',
        lat: (p['lat'] as num?)?.toDouble() ?? 0,
        lng: (p['lng'] as num?)?.toDouble() ?? 0,
        accuracyM: (p['accuracyM'] as num?)?.toDouble() ?? 0,
        timestamp: DateTime.tryParse((p['timestamp'] ?? p['ts'])?.toString() ?? ''),
      ),
  ];
  pings.sort((a, b) {
    final at = a.timestamp, bt = b.timestamp;
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return at.compareTo(bt);
  });
  return pings;
});
