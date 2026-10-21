import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/models.dart';
import 'auth_provider.dart';
import 'world_class_provider.dart';

/// Full family overview for the dashboard; refresh via `ref.invalidate(familyProvider)`.
final familyProvider = FutureProvider<FamilyOverview>((ref) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/family/me');
  return FamilyOverview.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Consent status and record history for one child
/// (`GET /v1/family/children/:id/consent`, ADR-0008). Refresh after a revoke
/// with `ref.invalidate(consentStatusProvider(childId))`.
final consentStatusProvider = FutureProvider.family<ConsentStatus, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/family/children/$childId/consent');
  return ConsentStatus.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Optional filters for [alertsProvider].
class AlertFilter {
  final String? childId;
  final String? severity;
  final bool? acknowledged;

  const AlertFilter({this.childId, this.severity, this.acknowledged});

  /// Query-string representation (unset fields are omitted).
  Map<String, dynamic> toQuery() => {
        if (childId != null) 'childId': childId,
        if (severity != null) 'severity': severity,
        if (acknowledged != null) 'ack': acknowledged.toString(),
      };

  @override
  bool operator ==(Object other) =>
      other is AlertFilter && other.childId == childId && other.severity == severity && other.acknowledged == acknowledged;

  @override
  int get hashCode => Object.hash(childId, severity, acknowledged);
}

/// Paginated alerts for the given [AlertFilter].
final alertsProvider = FutureProvider.family<AlertsPage, AlertFilter>((ref, filter) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/alerts', queryParameters: {'page': 1, 'limit': 50, ...filter.toQuery()});
  return AlertsPage.fromJson(res.data);
});

/// Unacknowledged alert count for the dashboard badge.
final unacknowledgedCountProvider = FutureProvider<int>((ref) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/alerts', queryParameters: {'ack': 'false', 'limit': 1});
  final data = res.data;
  if (data is Map) {
    final meta = data['meta'];
    // NOTE: prefer meta.total when present; fall back to items.length.
    if (meta is Map && meta['total'] != null) return (meta['total'] as num).toInt();
    if (data['items'] is List) return (data['items'] as List).length;
    if (data['total'] != null) return (data['total'] as num).toInt();
  } else if (data is List) {
    return data.length;
  }
  return 0;
});

/// RuleSet for one child (`GET /v1/rules/:childId`).
final rulesProvider = FutureProvider.family<RuleSet, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/rules/$childId');
  return RuleSet.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Roadmap 3.4: the installed-launchable apps reported by one child's device(s),
/// unioned by package id. The Rules editor's picker reads this so a parent can
/// choose a real app instead of typing a package id. A child with no paired
/// device, or a device that has not checked in yet, yields an empty report.
final installedAppsProvider = FutureProvider.family<InstalledAppsReport, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final overview = await ref.watch(familyProvider.future);
  var report = const InstalledAppsReport();
  for (final device in overview.devicesFor(childId)) {
    final res = await api.raw.get('/v1/devices/${device.id}/apps');
    if (res.data is! Map) continue;
    report = report.merge(InstalledAppsReport.fromJson(Map<String, dynamic>.from(res.data as Map)));
  }
  return report;
});

/// Latest location ping for one child (`GET /v1/location/:childId/latest`).
final locationProvider = FutureProvider.family<LocationPing?, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/location/$childId/latest');
  if (res.data is! Map) return null;
  final latest = (res.data as Map)['latest'];
  if (latest is! Map) return null;
  return LocationPing.fromJson(Map<String, dynamic>.from(latest));
});

/// Recent durable commands for one device (`GET /v1/devices/:id/commands/history`,
/// newest first). The parent-facing counterpart of the agent's drain endpoint:
/// it never consumes anything, so polling it is safe.
final deviceCommandHistoryProvider = FutureProvider.family<List<DeviceCommand>, String>((ref, deviceId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/devices/$deviceId/commands/history', queryParameters: {'limit': 20});
  final data = res.data is Map ? res.data as Map : const <String, dynamic>{};
  final raw = data['items'];
  return [
    for (final item in (raw as List? ?? const []))
      if (item is Map) DeviceCommand.fromJson(Map<String, dynamic>.from(item)),
  ];
});

/// Geofences for one child (`GET /v1/location/geofences/:childId`).
final geofencesProvider = FutureProvider.family<List<Geofence>, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/location/geofences/$childId');
  final raw = res.data is Map ? (res.data as Map)['items'] ?? (res.data as Map)['geofences'] : res.data;
  return [for (final g in (raw as List? ?? const [])) Geofence.fromJson(Map<String, dynamic>.from(g as Map))];
});

/// Family invites (`GET /v1/family/invites`, feature #13). Refresh after
/// create/revoke via `ref.invalidate(familyInvitesProvider)`.
final familyInvitesProvider = FutureProvider<List<FamilyInvite>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/family/invites');
  final map = res.data is Map ? res.data as Map : const {};
  final raw = map['items'] ?? map['invites'] ?? res.data;
  return [for (final i in (raw as List? ?? const [])) FamilyInvite.fromJson(Map<String, dynamic>.from(i as Map))];
});

/// What one realtime message asks the app to do. The socket layer is only a
/// transport: [applyRealtimeMessage] maps a decoded message onto this interface,
/// so the mapping is testable without a server (issue #236).
abstract class RealtimeEffects {
  /// `RealtimeEffects` backed by Riverpod, as [wsProvider] uses it.
  factory RealtimeEffects.fromRef(Ref ref) = RiverpodRealtimeEffects;

  void invalidateAlerts();
  void invalidateUnacknowledgedCount();
  void invalidateFamily();
  void invalidateLocation(String childId);

  /// Issue #253: an open consent screen watches `consentStatusProvider(childId)`, which nothing else
  /// refreshes. Revocation is exactly the moment that screen must stop saying "consented".
  void invalidateConsent(String childId);
  void updateLiveActivity(LiveActivity activity);
}

/// [RealtimeEffects] that invalidates the affected providers and writes the
/// `live_activity` overlay the dashboard reads.
class RiverpodRealtimeEffects implements RealtimeEffects {
  RiverpodRealtimeEffects(this._ref);

  final Ref _ref;

  @override
  void invalidateAlerts() => _ref.invalidate(alertsProvider);

  @override
  void invalidateUnacknowledgedCount() => _ref.invalidate(unacknowledgedCountProvider);

  @override
  void invalidateFamily() => _ref.invalidate(familyProvider);

  @override
  void invalidateLocation(String childId) => _ref.invalidate(locationProvider(childId));

  @override
  void invalidateConsent(String childId) => _ref.invalidate(consentStatusProvider(childId));

  @override
  void updateLiveActivity(LiveActivity activity) =>
      _ref.read(liveActivityProvider.notifier).update((m) => {...m, activity.childId: activity});
}

/// Maps one decoded `/v1/ws` message onto [effects]. Unknown types do nothing;
/// a `location` message without a `childId` refreshes only the family overview,
/// and a `live_activity` message without one is ignored (unchanged behaviour).
/// A `consent_revoked` message refreshes the family overview and, when it names
/// a child, that child's location (#253).
void applyRealtimeMessage(RealtimeEffects effects, Map<String, dynamic> msg) {
  switch (msg['type']) {
    case 'alert':
      effects.invalidateAlerts();
      effects.invalidateUnacknowledgedCount();
      effects.invalidateFamily();
    case 'location':
      final payload = msg['payload'];
      if (payload is Map && payload['childId'] != null) {
        effects.invalidateLocation(payload['childId'] as String);
      }
      effects.invalidateFamily();
    case 'consent_revoked':
      final payload = msg['payload'];
      if (payload is Map && payload['childId'] != null) {
        final childId = payload['childId'] as String;
        effects.invalidateLocation(childId);
        effects.invalidateConsent(childId);
      }
      effects.invalidateFamily();
    case 'live_activity':
      final payload = msg['payload'];
      if (payload is Map && payload['childId'] != null) {
        final activity = LiveActivity.fromJson(Map<String, dynamic>.from(payload));
        effects.updateLiveActivity(activity);
      }
  }
}

/// Live `/v1/ws` channel (http→ws scheme). Streams `{type, payload, ts}`
/// events and applies them through [applyRealtimeMessage].
/// The URL derives from the runtime Dio base so a persisted server override
/// (login screen) is honored without editing api/client.dart.
///
/// Reconnect: when the stream ends or errors, the next attempt is scheduled
/// with exponential backoff (1s → 30s cap, ~10 tries) via [wsRetryCountProvider];
/// the timer is cancelled on provider disposal.
final wsProvider = FutureProvider<WebSocketChannel?>((ref) async {
  final api = ref.watch(apiClientProvider);
  final baseUrl = api.raw.options.baseUrl;
  if (baseUrl.isEmpty) return null; // no server configured yet (fresh install)
  String? token;
  try {
    token = await const FlutterSecureStorage().read(key: 'jwt');
  } catch (_) {
    token = null;
  }
  if (token == null) return null;
  // Handoff item 6: connect with a single-use WS ticket so the JWT never appears in the URL.
  String ticket;
  try {
    final res = await api.raw.post('/v1/ws-ticket');
    ticket = (res.data as Map)['ticket'] as String;
  } catch (_) {
    return null; // no ticket -> stay dark; the next reconnect attempt fetches a fresh one
  }
  final base = Uri.parse(baseUrl);
  final scheme = base.scheme == 'https' ? 'wss' : 'ws';
  final uri = Uri(scheme: scheme, host: base.host, port: base.port, path: '/v1/ws', queryParameters: {'ticket': ticket});
  final channel = WebSocketChannel.connect(uri);

  Timer? reconnectTimer;
  var disposed = false;

  void scheduleReconnect() {
    if (disposed) return;
    reconnectTimer?.cancel();
    final next = ref.read(wsRetryCountProvider) + 1;
    if (next > 10) return; // ~10 tries, then stay dark until the next explicit refresh
    ref.read(wsRetryCountProvider.notifier).state = next;
    final delay = Duration(milliseconds: math.min(30000, 1000 * math.pow(2, next - 1).toInt()));
    reconnectTimer = Timer(delay, () {
      if (!disposed) ref.invalidateSelf();
    });
  }

  ref.onDispose(() {
    disposed = true;
    reconnectTimer?.cancel();
    channel.sink.close();
  });
  channel.stream.listen((event) {
    Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(jsonDecode(event as String) as Map);
    } catch (_) {
      return;
    }
    applyRealtimeMessage(RealtimeEffects.fromRef(ref), msg);
  }, onError: (_) => scheduleReconnect(), onDone: scheduleReconnect);
  return channel;
});

/// Consecutive WS reconnect attempts within the current [wsProvider] run;
/// reset by consumers on a successful connection if needed.
final wsRetryCountProvider = StateProvider<int>((ref) => 0);
