import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/models.dart';
import 'auth_provider.dart';
import 'world_class_provider.dart';

import '../api/permission_errors.dart';

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

/// Outcome of resolving a single alert by ID within the guardian's `/v1/alerts` scope.
enum AlertLookupStatus {
  /// Matching alert was resolved.
  found,

  /// All available pages were scanned and the alert is absent.
  notFound,

  /// Bounded page scan stopped while the server confirmed additional pages remain.
  incompleteScan,
}

/// Typed result for [alertByIdProvider] so an incomplete bounded scan is never reported
/// as a missing alert.
class AlertLookupResult {
  final AlertLookupStatus status;
  final Alert? alert;

  const AlertLookupResult.found(Alert this.alert) : status = AlertLookupStatus.found;
  const AlertLookupResult.notFound()
      : status = AlertLookupStatus.notFound,
        alert = null;
  const AlertLookupResult.incompleteScan()
      : status = AlertLookupStatus.incompleteScan,
        alert = null;
}

/// Resolves a single alert by [alertId] within the guardian's authorized `/v1/alerts` scope,
/// checking page 1 via [alertsProvider] first and paginating up to [maxPages] before reporting
/// either [AlertLookupStatus.notFound] (exhausted) or [AlertLookupStatus.incompleteScan]
/// (more pages exist beyond the bounded cap).
final alertByIdProvider = FutureProvider.family<AlertLookupResult, String>((ref, alertId) async {
  const pageLimit = 50;
  const maxPages = 20;
  final firstPage = await ref.watch(alertsProvider(const AlertFilter()).future);
  final firstHit = firstPage.items.where((a) => a.id == alertId).firstOrNull;
  if (firstHit != null) return AlertLookupResult.found(firstHit);

  var seen = firstPage.items.length;
  final total = firstPage.total;
  if (seen == 0 || seen >= total) return const AlertLookupResult.notFound();

  final api = ref.watch(apiClientProvider);
  var exhausted = false;
  for (var page = 2; page <= maxPages && seen < total; page++) {
    final res = await api.raw.get(
      '/v1/alerts',
      queryParameters: {'page': page, 'limit': pageLimit},
    );
    final nextPage = AlertsPage.fromJson(res.data);
    if (nextPage.items.isEmpty) {
      exhausted = true;
      break;
    }
    final hit = nextPage.items.where((a) => a.id == alertId).firstOrNull;
    if (hit != null) return AlertLookupResult.found(hit);
    seen += nextPage.items.length;
  }
  if (!exhausted && seen < total) {
    return const AlertLookupResult.incompleteScan();
  }
  return const AlertLookupResult.notFound();
});

/// Snapshot of unacknowledged alerts returned by `GET /v1/alerts?ack=false`.
class UnacknowledgedAlertsSummary {
  final int total;
  final List<Alert> items;

  const UnacknowledgedAlertsSummary({
    required this.total,
    this.items = const [],
  });
}

/// Server-side unacknowledged alerts summary (`GET /v1/alerts?ack=false`).
final unacknowledgedAlertsProvider = FutureProvider<UnacknowledgedAlertsSummary>((ref) async {
  final api = ref.watch(apiClientProvider);
  final Response<dynamic> res;
  try {
    res = await api.raw.get('/v1/alerts', queryParameters: {'ack': 'false', 'limit': 50});
  } on DioException catch (e) {
    // ADR-0014 amendment, decision 7: a guardian whose invite lacks `alerts` is refused this read, and
    // that must mean "no badge", not a dashboard error. Any other failure still surfaces as before.
    if (ReadPermissionRequired.from(e) != null) return const UnacknowledgedAlertsSummary(total: 0);
    rethrow;
  }
  final data = res.data;
  if (data is Map) {
    final map = Map<String, dynamic>.from(data);
    final page = AlertsPage.fromJson(map);
    final meta = map['meta'];
    final total = meta is Map && meta['total'] != null
        ? (meta['total'] as num).toInt()
        : page.total;
    return UnacknowledgedAlertsSummary(total: total, items: page.items);
  } else if (data is List) {
    final items = [
      for (final raw in data)
        if (raw is Map) Alert.fromJson(Map<String, dynamic>.from(raw)),
    ];
    return UnacknowledgedAlertsSummary(total: items.length, items: items);
  }
  return const UnacknowledgedAlertsSummary(total: 0);
});

/// Unacknowledged alert count on the server (keeps explicit acknowledgement count intact).
final unacknowledgedCountProvider = FutureProvider<int>((ref) async {
  final summary = await ref.watch(unacknowledgedAlertsProvider.future);
  return summary.total;
});

/// `shared_preferences` key for which unacknowledged alerts the parent has
/// already viewed by opening the Notifications feed (#936).
const kAlertsSeenStateKey = 'alerts_seen_state_v1';

/// Client-side seen state for the dashboard Notifications bell (#936).
/// Viewing the feed clears the bell badge while leaving server `acknowledged`
/// untouched for explicit incident acknowledgement.
class AlertsSeenState {
  final bool hasViewedFeed;
  final int seenUnackedBaseline;
  final Map<String, int> seenVersions;
  /// #1029: social alert `id -> socialMessageCount` at the last time the parent opened it.
  /// Only alerts present here show a `+{delta} new` badge when more flagged messages arrive.
  final Map<String, int> openedSocialCounts;

  const AlertsSeenState({
    this.hasViewedFeed = false,
    this.seenUnackedBaseline = 0,
    this.seenVersions = const {},
    this.openedSocialCounts = const {},
  });

  static const empty = AlertsSeenState();

  factory AlertsSeenState.fromJson(Map<String, dynamic> json) {
    Map<String, int> parseIntMap(Object? raw) {
      final out = <String, int>{};
      if (raw is Map) {
        for (final entry in raw.entries) {
          final v = entry.value;
          if (entry.key is String && v is num) {
            out[entry.key as String] = v.toInt();
          }
        }
      }
      return out;
    }

    return AlertsSeenState(
      hasViewedFeed: json['v'] == true,
      seenUnackedBaseline: (json['b'] as num?)?.toInt() ?? 0,
      seenVersions: parseIntMap(json['s']),
      openedSocialCounts: parseIntMap(json['oc']),
    );
  }

  Map<String, dynamic> toJson() => {
        'v': hasViewedFeed,
        'b': seenUnackedBaseline,
        's': seenVersions,
        if (openedSocialCounts.isNotEmpty) 'oc': openedSocialCounts,
      };
}

class AlertsSeenNotifier extends StateNotifier<AlertsSeenState> {
  AlertsSeenNotifier() : super(AlertsSeenState.empty);

  bool _disposed = false;
  bool _userUpdated = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kAlertsSeenStateKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final saved = AlertsSeenState.fromJson(Map<String, dynamic>.from(decoded));
      if (!_disposed && !_userUpdated) state = saved;
    } catch (_) {
      // Missing prefs mock in isolated tests falls back to in-memory state.
    }
  }

  Future<void> _persist(AlertsSeenState next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kAlertsSeenStateKey, jsonEncode(next.toJson()));
    } catch (_) {
      // Best-effort persistence; in-memory state already reflects the action.
    }
  }

  /// Marks all currently loaded feed items (and any fetched `ack=false` snapshot)
  /// as seen after page 1 of `/alerts` completes cleanly.
  Future<void> markFeedViewed(
    Iterable<Alert> loadedItems, {
    int? unackedTotalSnapshot,
    Iterable<Alert>? unackedItemsSnapshot,
  }) async {
    _userUpdated = true;
    final merged = Map<String, int>.from(state.seenVersions);
    for (final a in loadedItems) {
      if (a.acknowledged) {
        merged.remove(a.id);
      } else {
        final prev = merged[a.id] ?? 0;
        if (a.attemptCount > prev) merged[a.id] = a.attemptCount;
      }
    }
    if (unackedItemsSnapshot != null) {
      for (final a in unackedItemsSnapshot) {
        if (!a.acknowledged) {
          final prev = merged[a.id] ?? 0;
          if (a.attemptCount > prev) merged[a.id] = a.attemptCount;
        }
      }
    }
    final pageUnackedCount = loadedItems.where((a) => !a.acknowledged).length;
    final baseline = unackedTotalSnapshot ?? pageUnackedCount;
    final next = AlertsSeenState(
      hasViewedFeed: true,
      seenUnackedBaseline: baseline,
      seenVersions: merged,
      openedSocialCounts: state.openedSocialCounts,
    );
    state = next;
    await _persist(next);
  }

  /// #1029: records that the parent opened [alert] at its current message count,
  /// clearing any `+{count} new` badge until additional flagged messages arrive.
  Future<void> markAlertOpened(Alert alert) async {
    if (!alert.isSocialAlert) return;
    _userUpdated = true;
    final opened = Map<String, int>.from(state.openedSocialCounts);
    final prevOpened = opened[alert.id] ?? 0;
    final currentCount = alert.socialMessageCount;
    if (currentCount > prevOpened) {
      opened[alert.id] = currentCount;
    } else if (!opened.containsKey(alert.id)) {
      opened[alert.id] = currentCount;
    }
    final versions = Map<String, int>.from(state.seenVersions);
    final prevVer = versions[alert.id] ?? 0;
    if (alert.attemptCount > prevVer) versions[alert.id] = alert.attemptCount;
    final next = AlertsSeenState(
      hasViewedFeed: state.hasViewedFeed,
      seenUnackedBaseline: state.seenUnackedBaseline,
      seenVersions: versions,
      openedSocialCounts: opened,
    );
    state = next;
    await _persist(next);
  }

  /// Adjusts seen tracking when the parent explicitly acknowledges [alertId]
  /// so the count-only fallback stays aligned with the decremented server total.
  Future<void> markAcknowledged(String alertId) async {
    _userUpdated = true;
    final merged = Map<String, int>.from(state.seenVersions)..remove(alertId);
    final opened = Map<String, int>.from(state.openedSocialCounts)..remove(alertId);
    final nextBaseline = state.seenUnackedBaseline > 0 ? state.seenUnackedBaseline - 1 : 0;
    final next = AlertsSeenState(
      hasViewedFeed: state.hasViewedFeed,
      seenUnackedBaseline: nextBaseline,
      seenVersions: merged,
      openedSocialCounts: opened,
    );
    state = next;
    await _persist(next);
  }

  Future<void> clear() async {
    _userUpdated = true;
    state = AlertsSeenState.empty;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kAlertsSeenStateKey);
    } catch (_) {}
  }
}

final alertsSeenProvider = StateNotifierProvider<AlertsSeenNotifier, AlertsSeenState>((ref) {
  final notifier = AlertsSeenNotifier();
  notifier.load();
  ref.listen(authProvider, (prev, next) {
    if ((prev?.isAuthenticated ?? false) && !next.isAuthenticated) {
      notifier.clear();
    }
  });
  return notifier;
});

/// #1029: returns how many additional flagged messages have arrived on [alert]
/// since the parent last opened it. Returns 0 if never opened yet or if no new
/// messages have arrived since opening.
int computeSocialNewSinceCount(Alert alert, AlertsSeenState seen) {
  if (!alert.isSocialAlert) return 0;
  final openedAt = seen.openedSocialCounts[alert.id];
  if (openedAt == null) return 0;
  final current = alert.socialMessageCount;
  return current > openedAt ? current - openedAt : 0;
}

/// Computes how many unacknowledged alerts have not yet been viewed on `/alerts` (#936).
int computeUnseenAlertCount(
  UnacknowledgedAlertsSummary summary,
  AlertsSeenState seen,
) {
  if (summary.total <= 0) return 0;
  if (!seen.hasViewedFeed) return summary.total;
  if (summary.items.isNotEmpty) {
    var unseenInPage = 0;
    for (final alert in summary.items) {
      if (alert.acknowledged) continue;
      final seenAttempt = seen.seenVersions[alert.id];
      if (seenAttempt == null || alert.attemptCount > seenAttempt) {
        unseenInPage++;
      }
    }
    final coveredBaseline =
        summary.items.length > seen.seenUnackedBaseline ? summary.items.length : seen.seenUnackedBaseline;
    final overflow = summary.total > summary.items.length ? summary.total - coveredBaseline : 0;
    return unseenInPage + (overflow > 0 ? overflow : 0);
  }
  final delta = summary.total - seen.seenUnackedBaseline;
  return delta > 0 ? delta : 0;
}

/// Displayed bell badge count on the dashboard (#936): cleared when `/alerts`
/// loads cleanly, preserved on feed failure, and incremented on later alerts.
final alertsBadgeCountProvider = Provider<AsyncValue<int>>((ref) {
  final summaryAsync = ref.watch(unacknowledgedAlertsProvider);
  final seen = ref.watch(alertsSeenProvider);
  return summaryAsync.whenData((summary) => computeUnseenAlertCount(summary, seen));
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
    try {
      final res = await api.raw.get('/v1/devices/${device.id}/apps');
      if (res.data is! Map) continue;
      report = report.merge(InstalledAppsReport.fromJson(Map<String, dynamic>.from(res.data as Map)));
    } on DioException catch (e) {
      // Antigravity's #872 finding 3: a `pending` device answers 404 here (`requireFamily hidePending`),
      // and one sibling's 404 used to throw the whole future away — which hid the *first* phone's app
      // names behind the "pending" line. Only "this phone has no report" is skippable; a 500 or an auth
      // failure is a real load failure and stays one, exactly as in the per-device provider below.
      if (e.response?.statusCode != 404) rethrow;
    }
  }
  return report;
});

/// U33 (#868): the same inventory kept per device, so the picker can group rows under the device that
/// reported them. Devices arrive in the family overview's order. One phone that fails to answer leaves
/// its own group empty instead of emptying the whole picker — the other devices still list their apps.
final installedAppsByDeviceProvider =
    FutureProvider.family<List<DeviceApps>, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final overview = await ref.watch(familyProvider.future);
  final groups = <DeviceApps>[];
  for (final device in overview.devicesFor(childId)) {
    var report = const InstalledAppsReport();
    try {
      final res = await api.raw.get('/v1/devices/${device.id}/apps');
      if (res.data is Map) {
        report = InstalledAppsReport.fromJson(
            Map<String, dynamic>.from(res.data as Map));
      }
    } on DioException catch (e) {
      // Only "this phone has no report" is an empty group: the API answers 404 for a device that has
      // never uploaded. Anything else (a 500, an auth failure) is a real load failure and stays one —
      // the picker shows its error with a retry rather than an empty list that reads as "no apps".
      if (e.response?.statusCode != 404) rethrow;
    }
    groups.add(DeviceApps(
      deviceId: device.id,
      label: device.model.trim().isEmpty ? device.platform : device.model.trim(),
      report: report,
    ));
  }
  return groups;
});

/// Latest location ping for one child (`GET /v1/location/:childId/latest`).
final locationProvider = FutureProvider.family<LocationPing?, String>((ref, childId) async {
  final api = ref.watch(apiClientProvider);
  final Response<dynamic> res;
  try {
    res = await api.raw.get('/v1/location/$childId/latest');
  } on DioException catch (e) {
    // #850: a child that has never reported a location answers 404. That is the empty state
    // ("No location reported yet"), not an error, so the tab must not show exception text.
    if (e.response?.statusCode == 404) return null;
    rethrow;
  }
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

/// The ring the parent's **Stop** must target: the newest ring command the device may still be ringing — `pending`
/// (sent, not fetched yet) or `delivered` (fetched; its acknowledgement can be late).
///
/// This used to take the newest `acked` row, and that is the bug Codex found (#760 `7158872749`): `acked` means the
/// device already settled that ring (`ackRingCommandOnReport`, `services/api/src/lib/deviceCommands.ts:78-88`), so a
/// parent who pressed Stop while a newer ring was starting aimed at a ring that had ended. The id is only useful
/// while the ring is live, and live is exactly `pending` or `delivered` — the same rule the server applies to its own
/// ring rows (`:64`). A `failed` or `expired` row is not live, and no ring at all still gives null.
String? activeRingId(List<DeviceCommand> commands) {
  for (final command in commands) {
    if (command.type == 'ring' && (command.status == 'pending' || command.status == 'delivered')) {
      return command.id;
    }
  }
  return null;
}

Future<String?> ringStopTarget(WidgetRef ref, String deviceId) async {
  try {
    return activeRingId(await ref.read(deviceCommandHistoryProvider(deviceId).future));
  } catch (_) {
    return null;
  }
}

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

  /// #876: the delivery list on a child page. The `rules_applied` frame means a command just completed, so
  /// the list it belongs to is stale — refreshing it here is what turns "pending" into "delivered" without
  /// adding a poll loop of its own.
  void invalidateCommandHistory();
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
  void invalidateUnacknowledgedCount() {
    _ref.invalidate(unacknowledgedAlertsProvider);
    _ref.invalidate(unacknowledgedCountProvider);
  }

  @override
  void invalidateFamily() => _ref.invalidate(familyProvider);

  @override
  void invalidateLocation(String childId) => _ref.invalidate(locationProvider(childId));

  @override
  void invalidateConsent(String childId) => _ref.invalidate(consentStatusProvider(childId));

  @override
  void invalidateCommandHistory() => _ref.invalidate(deviceCommandHistoryProvider);

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
    case 'rules_applied':
      // #865: the family's lowest applied rules version reached what the server issued, so the
      // "hasn't picked this change up yet" line (which reads that number) is stale from here on.
      // #876: the same frame says the rules command that carried the change has landed, so the delivery
      // list is stale too. Two indicators, one frame, no extra polling.
      effects.invalidateFamily();
      effects.invalidateCommandHistory();
    case 'command_acked':
      // #935: a child device acknowledged a command (lock, pause, resume, etc.), so the delivery
      // summary and command history are stale right away rather than waiting ~15 s.
      effects.invalidateCommandHistory();
      effects.invalidateFamily();
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
