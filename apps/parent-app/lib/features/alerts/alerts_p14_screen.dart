import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/date_formatting.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../children/child_detail_screen.dart' show AlertTile;
import 'alert_detail_screen.dart';
import 'alerts_screen.dart' show AlertsScreen, mergeAlertsInPlace;
import 'app_alert_presentation.dart';

/// Feature flag for P-14 Alerts list (#1231).
/// Enable at build time via `--dart-define=OSRA_UX_P14=true` or
/// `--dart-define=OSRA_UX_FINAL=true`, or override [p14AlertsEnabledProvider]
/// in tests.
const bool kP14AlertsDefault = bool.fromEnvironment(
  'OSRA_UX_P14',
  defaultValue: bool.fromEnvironment('OSRA_UX_FINAL', defaultValue: false),
);

final p14AlertsEnabledProvider = Provider<bool>((_) => kP14AlertsDefault);

/// Three parent-facing levels mapped 1:1 from server severity (gap check G9).
enum P14AlertLevel { urgent, checkSoon, info }

/// Two segments on P-14 Alerts list (#1231).
enum P14Segment { alerts, requests }

/// Maps server severity (`critical | warning | info`) 1:1 to P-14 levels (G9).
P14AlertLevel p14LevelForSeverity(String severity) {
  return switch (severity.toLowerCase()) {
    'critical' => P14AlertLevel.urgent,
    'warning' => P14AlertLevel.checkSoon,
    _ => P14AlertLevel.info,
  };
}

/// Routes parent decision requests to the Requests segment by `requestType` /
/// request category rather than severity (G9).
bool isP14RequestAlert(Alert alert) =>
    isParentDecisionAlert(alert) || alert.category == 'install_request';

/// Counts alerts that earn the Alerts badge (G9 + UI/UX Bureau #1179):
/// - Unacknowledged Urgent (`critical`) and Check soon (`warning`) alerts.
/// - Unacknowledged Requests (even though their server severity is `info`).
/// - Plain `info` alerts (including ordinary blocked-app / blocked-site
///   attempts) stay OFF the badge.
@visibleForTesting
int computeP14BadgeCount(Iterable<Alert> alerts) {
  var count = 0;
  for (final a in alerts) {
    if (a.acknowledged) continue;
    if (isP14RequestAlert(a)) {
      count++;
      continue;
    }
    final level = p14LevelForSeverity(a.severity);
    if (level == P14AlertLevel.urgent || level == P14AlertLevel.checkSoon) {
      count++;
    }
  }
  return count;
}

/// Sorts alerts descending by [Alert.effectiveTimestamp] (`latestAt` ->
/// `lastAt` -> `updatedAt` -> `createdAt`) so grouped rows updated in place
/// move to the top (#1139 / #1222).
@visibleForTesting
List<Alert> sortP14Alerts(Iterable<Alert> alerts) {
  final sorted = alerts.toList();
  sorted.sort((a, b) {
    final ta = a.effectiveTimestamp;
    final tb = b.effectiveTimestamp;
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  });
  return sorted;
}

/// Effective repeat count for a grouped alert row (#1139 / #1222).
int p14GroupCount(Alert alert) =>
    alert.isSocialAlert ? alert.socialMessageCount : alert.attemptCount;

/// Routes `/alerts` to [AlertsP14Screen] when `OSRA_UX_P14` is enabled, or
/// falls back to the legacy [AlertsScreen] when switched off.
class AlertsRouteEntry extends ConsumerWidget {
  const AlertsRouteEntry({
    super.key,
    this.initialChildId,
    this.initialSegment = P14Segment.alerts,
  });

  final String? initialChildId;
  final P14Segment initialSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(p14AlertsEnabledProvider)) {
      return AlertsP14Screen(
        initialChildId: initialChildId,
        initialSegment: initialSegment,
      );
    }
    return const AlertsScreen();
  }
}

/// P-14 Alerts list (#1231):
/// - Two segments: Alerts / Requests (G9).
/// - Three levels: Urgent / Check soon / Info, grouped by local day.
/// - Child filter chips (A25).
/// - Grouped rows show count + latest time and sort by `latestAt` (#1139/#1222).
/// - Pull-to-refresh (#1214) and live refresh on `/v1/ws` updates.
/// - Opening an alert opens P-15 (`AlertDetailScreen`) without marking it
///   reviewed; no swipe-to-dismiss and no mark-all-read.
class AlertsP14Screen extends ConsumerStatefulWidget {
  const AlertsP14Screen({
    super.key,
    this.initialChildId,
    this.initialSegment = P14Segment.alerts,
    @visibleForTesting this.nowProvider,
    @visibleForTesting this.liveRefreshInterval = const Duration(seconds: 30),
  });

  final String? initialChildId;
  final P14Segment initialSegment;
  final DateTime Function()? nowProvider;
  final Duration liveRefreshInterval;

  @override
  ConsumerState<AlertsP14Screen> createState() => _AlertsP14ScreenState();
}

class _AlertsP14ScreenState extends ConsumerState<AlertsP14Screen> {
  final List<Alert> _items = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _liveRefreshing = false;
  Timer? _liveRefreshTimer;
  String? _error;
  ReadPermissionRequired? _refused;

  late P14Segment _segment;
  String? _selectedChildId;

  @override
  void initState() {
    super.initState();
    _segment = widget.initialSegment;
    _selectedChildId =
        (widget.initialChildId != null && widget.initialChildId!.trim().isNotEmpty)
            ? widget.initialChildId!.trim()
            : null;
    _loadMore();
    if (widget.liveRefreshInterval > Duration.zero) {
      _liveRefreshTimer = Timer.periodic(
        widget.liveRefreshInterval,
        (_) => _refreshLivePage(),
      );
    }
  }

  @override
  void dispose() {
    _liveRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLivePage() async {
    if (!mounted || _loading || _liveRefreshing || _refused != null) return;
    _liveRefreshing = true;
    try {
      final res = await ref
          .read(apiClientProvider)
          .raw
          .get('/v1/alerts', queryParameters: {'page': 1, 'limit': 20});
      if (!mounted) return;
      final pageData = AlertsPage.fromJson(res.data);
      setState(() {
        final merged = sortP14Alerts(mergeAlertsInPlace(_items, pageData.items));
        _items
          ..clear()
          ..addAll(merged);
        if (_page == 0) _page = 1;
        _hasMore = pageData.items.isNotEmpty && _items.length < pageData.total;
      });
    } on DioException {
      // Transient background refresh failure keeps the visible feed intact.
    } finally {
      _liveRefreshing = false;
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
      _refused = null;
    });
    try {
      final res = await ref
          .read(apiClientProvider)
          .raw
          .get('/v1/alerts', queryParameters: {'page': _page + 1, 'limit': 20});
      if (!mounted) return;
      final pageData = AlertsPage.fromJson(res.data);
      final isFirstPage = _page == 0;
      setState(() {
        _page++;
        final merged = sortP14Alerts(mergeAlertsInPlace(_items, pageData.items));
        _items
          ..clear()
          ..addAll(merged);
        _hasMore = pageData.items.isNotEmpty && _items.length < pageData.total;
      });
      if (isFirstPage) {
        final summary = ref.read(unacknowledgedAlertsProvider).valueOrNull;
        ref.read(alertsSeenProvider.notifier).markFeedViewed(
              pageData.items,
              unackedTotalSnapshot: summary?.total,
              unackedItemsSnapshot: summary?.items,
            );
      }
    } on DioException catch (e) {
      if (!mounted) return;
      final refused = ReadPermissionRequired.from(e);
      setState(() {
        _refused = refused;
        _error = refused == null
            ? friendlyErrorText(
                context.l10n,
                e,
                () => context.l10n.alertsLoadFailed,
              )
            : null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _page = 0;
      _hasMore = true;
      _error = null;
      _refused = null;
    });
    await _loadMore();
  }

  void _openDetail(Alert alert) {
    // Opening an alert opens P-15 without marking it reviewed/acknowledged.
    if (alert.isSocialAlert) {
      ref.read(alertsSeenProvider.notifier).markAlertOpened(alert);
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.push('/alerts/${Uri.encodeComponent(alert.id)}', extra: alert);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AlertDetailScreen(
            alertId: alert.id,
            initialAlert: alert,
            nowProvider: widget.nowProvider,
          ),
        ),
      );
    }
  }

  void _requestResolved(Alert alert, String resolution, DateTime at) {
    final updated = alert.copyWith(
      acknowledged: true,
      updatedAt: at,
      metadata: {
        ...alert.metadata,
        'resolution': resolution,
        'resolvedAt': at.toUtc().toIso8601String(),
      },
    );
    _mergeRequestResolution(updated);
  }

  void _mergeRequestResolution(Alert updated) {
    final merged = sortP14Alerts(mergeAlertsInPlace(_items, [updated]));
    setState(() {
      _items
        ..clear()
        ..addAll(merged);
    });
  }

  String _dayLabel(BuildContext context, String key) {
    if (key == 'Unknown') return context.l10n.unknown;
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    return normalizeDigits(formatDayHeader(d, context.localeName));
  }

  String _clockLabel(DateTime ts) {
    final clock = normalizeDigits(DateFormat('HH:mm', 'en').format(ts.toLocal()));
    return ltrIsolate(clock);
  }

  String _levelLabel(AppLocalizations l10n, P14AlertLevel level) {
    return switch (level) {
      P14AlertLevel.urgent => l10n.p14LevelUrgent,
      P14AlertLevel.checkSoon => l10n.p14LevelCheckSoon,
      P14AlertLevel.info => l10n.p14LevelInfo,
    };
  }

  Color _levelColor(BuildContext context, P14AlertLevel level) {
    final tokens = context.tokens;
    return switch (level) {
      P14AlertLevel.urgent => tokens.danger,
      P14AlertLevel.checkSoon => tokens.warn,
      P14AlertLevel.info => Theme.of(context).colorScheme.primary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final seen = ref.watch(alertsSeenProvider);
    final family = ref.watch(familyProvider).valueOrNull;
    final children = family?.children ?? const [];
    final childNames = <String, String>{
      for (final c in children) c.id: c.displayName,
    };

    // Realtime /v1/ws updates merge in place and re-sort by effectiveTimestamp.
    ref.listen<AsyncValue<AlertsPage>>(alertsProvider(const AlertFilter()),
        (_, next) {
      if (next is! AsyncData<AlertsPage> || !mounted) return;
      final merged = sortP14Alerts(mergeAlertsInPlace(_items, next.value.items));
      setState(() {
        _items
          ..clear()
          ..addAll(merged);
      });
    });

    final childFiltered = _selectedChildId == null
        ? _items
        : _items.where((a) => a.childId == _selectedChildId).toList();

    final alertItems =
        sortP14Alerts(childFiltered.where((a) => !isP14RequestAlert(a)));
    final requestItems =
        sortP14Alerts(childFiltered.where(isP14RequestAlert));

    final alertsBadge = computeP14BadgeCount(alertItems);
    final requestsBadge = computeP14BadgeCount(requestItems);

    final activeItems =
        _segment == P14Segment.alerts ? alertItems : requestItems;

    // Group active items by local day using effectiveTimestamp (latestAt).
    final groups = <String, List<Alert>>{};
    final dayOrder = <String>[];
    for (final a in activeItems) {
      final ts = a.effectiveTimestamp;
      final day = ts == null ? 'Unknown' : dayKey(ts.toLocal());
      if (!groups.containsKey(day)) {
        groups[day] = [];
        dayOrder.add(day);
      }
      groups[day]!.add(a);
    }
    dayOrder.sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.alertsTitle)),
      body: _refused != null && _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Text(
                  l10n.readPermissionRequired,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _error != null && _items.isEmpty
              ? ErrorRetryView(message: _error!, onRetry: _refresh)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.lg,
                        AppSpace.sm,
                        AppSpace.lg,
                        AppSpace.xs,
                      ),
                      child: _P14SegmentBar(
                        selected: _segment,
                        alertsLabel: l10n.tabAlerts,
                        requestsLabel: l10n.p14SegmentRequests,
                        alertsCount: alertsBadge,
                        requestsCount: requestsBadge,
                        onSelected: (seg) => setState(() => _segment = seg),
                      ),
                    ),
                    if (children.isNotEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.lg,
                            vertical: AppSpace.xs,
                          ),
                          child: Row(
                            children: [
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: AppSpace.sm,
                                ),
                                child: FilterChip(
                                  key: const ValueKey('p14-child-all'),
                                  label: Text(l10n.p14FilterAll),
                                  selected: _selectedChildId == null,
                                  onSelected: (_) =>
                                      setState(() => _selectedChildId = null),
                                ),
                              ),
                              for (final child in children)
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    end: AppSpace.sm,
                                  ),
                                  child: FilterChip(
                                    key: ValueKey('p14-child-${child.id}'),
                                    label: Text(
                                      firstStrongIsolate(child.displayName),
                                    ),
                                    selected: _selectedChildId == child.id,
                                    onSelected: (_) => setState(
                                      () => _selectedChildId = child.id,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView(
                          key: const ValueKey('p14-alerts-list'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: AppSpace.xl),
                          children: [
                            if (_loading && _items.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 120),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else if (activeItems.isEmpty && !_loading)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  AppSpace.xl,
                                  120,
                                  AppSpace.xl,
                                  AppSpace.xl,
                                ),
                                child: Center(
                                  child: Text(
                                    _segment == P14Segment.alerts
                                        ? l10n.noAlertsYet
                                        : l10n.p14NoRequestsYet,
                                    key: const ValueKey('p14-empty-state'),
                                    textAlign: TextAlign.center,
                                    style:
                                        Theme.of(context).textTheme.bodyLarge,
                                  ),
                                ),
                              )
                            else
                              for (final day in dayOrder)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Padding(
                                      padding:
                                          const EdgeInsetsDirectional.fromSTEB(
                                        AppSpace.lg,
                                        AppSpace.md,
                                        AppSpace.lg,
                                        AppSpace.xs,
                                      ),
                                      child: Text(
                                        _dayLabel(context, day),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                      ),
                                    ),
                                    for (final alert in groups[day]!)
                                      _segment == P14Segment.requests
                                          ? AlertTile(
                                              key: ValueKey(
                                                  'p14-row-${alert.id}'),
                                              alert: alert,
                                              onRequestResolved:
                                                  (resolution, at) =>
                                                      _requestResolved(
                                                          alert, resolution, at),
                                              onTimeRequestResolved:
                                                  _mergeRequestResolution,
                                              onTap: () => _openDetail(alert),
                                            )
                                          : _P14AlertRowCard(
                                              key: ValueKey(
                                                  'p14-row-${alert.id}'),
                                              alert: alert,
                                              levelLabel: _levelLabel(
                                                l10n,
                                                p14LevelForSeverity(
                                                    alert.severity),
                                              ),
                                              levelColor: _levelColor(
                                                context,
                                                p14LevelForSeverity(
                                                    alert.severity),
                                              ),
                                              childName:
                                                  childNames[alert.childId],
                                              latestClock: alert
                                                          .effectiveTimestamp !=
                                                      null
                                                  ? _clockLabel(alert
                                                      .effectiveTimestamp!)
                                                  : null,
                                              newSinceCount:
                                                  computeSocialNewSinceCount(
                                                      alert, seen),
                                              now: widget.nowProvider?.call(),
                                              onTap: () => _openDetail(alert),
                                            ),
                                  ],
                                ),
                            if (_loading && _items.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.all(AppSpace.lg),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            if (!_loading && _hasMore && _items.isNotEmpty)
                              Center(
                                child: TextButton(
                                  key: const ValueKey('p14-load-more'),
                                  onPressed: _loadMore,
                                  child: Text(l10n.loadMore),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _P14SegmentBar extends StatelessWidget {
  const _P14SegmentBar({
    required this.selected,
    required this.alertsLabel,
    required this.requestsLabel,
    required this.alertsCount,
    required this.requestsCount,
    required this.onSelected,
  });

  final P14Segment selected;
  final String alertsLabel;
  final String requestsLabel;
  final int alertsCount;
  final int requestsCount;
  final ValueChanged<P14Segment> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _SegmentButton(
              key: const ValueKey('p14-seg-alerts'),
              label: alertsLabel,
              count: alertsCount,
              selected: selected == P14Segment.alerts,
              onTap: () => onSelected(P14Segment.alerts),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _SegmentButton(
              key: const ValueKey('p14-seg-requests'),
              label: requestsLabel,
              count: requestsCount,
              selected: selected == P14Segment.requests,
              onTap: () => onSelected(P14Segment.requests),
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = selected ? scheme.surface : Colors.transparent;
    final fg = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        elevation: selected ? 1 : 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: AppSpace.xs,
              ),
              child: Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpace.xs,
                  runSpacing: 2,
                  children: [
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: fg,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                    ),
                    if (count > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          normalizeDigits('$count'),
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: scheme.onPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _P14AlertRowCard extends ConsumerWidget {
  const _P14AlertRowCard({
    super.key,
    required this.alert,
    required this.levelLabel,
    required this.levelColor,
    required this.childName,
    required this.latestClock,
    required this.newSinceCount,
    required this.now,
    required this.onTap,
  });

  final Alert alert;
  final String levelLabel;
  final Color levelColor;
  final String? childName;
  final String? latestClock;
  final int newSinceCount;
  final DateTime? now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final isAppBlocked = alert.category == 'app_blocked';

    String title;
    if (isAppBlocked) {
      final installed = alertInstalledAppsReport(
        ref.watch(installedAppsByDeviceProvider(alert.childId)).valueOrNull,
        alert.deviceId,
      );
      final identity = resolveAppAlertIdentity(
        alert,
        installed,
        fallbackName: l10n.alertCategoryAppBlocked,
      );
      title = appAlertTitle(
        alert: alert,
        l10n: l10n,
        childName: childName,
        identity: identity,
      );
    } else if (alert.hasSocialCountSummary) {
      final appName = alert.metadata['app']?.toString().trim() ?? '';
      title = l10n.socialAlertCountTitle(
        alert.socialMessageCount,
        firstStrongIsolate(appName),
      );
    } else {
      title = l10n.alertTitleFor(
        alert.category,
        alert.title,
        isEnglish: context.localeName.startsWith('en'),
        tamperType: alert.metadata['type']?.toString(),
      );
    }

    final groupCount = p14GroupCount(alert);
    String? subtitle;
    if (groupCount > 1 && latestClock != null) {
      subtitle = l10n.p14GroupedCount(groupCount, latestClock!);
    } else if (isAppBlocked) {
      subtitle = appAlertBody(
        alert: alert,
        l10n: l10n,
        childName: childName,
      );
    } else {
      final body = formatGeneralAlertBody(
        alert,
        l10n: l10n,
        localeName: context.localeName,
        now: now,
      );
      if (body.isNotEmpty) subtitle = body;
    }

    final level = p14LevelForSeverity(alert.severity);
    final unreviewed = !alert.acknowledged &&
        (level == P14AlertLevel.urgent || level == P14AlertLevel.checkSoon);

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.xs,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: levelColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (unreviewed) ...[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: levelColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          levelLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: levelColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (childName != null && childName!.trim().isNotEmpty)
                    Text(
                      firstStrongIsolate(childName!.trim()),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (latestClock != null)
                    Text(
                      latestClock!,
                      key: ValueKey('p14-time-${alert.id}'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (newSinceCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        l10n.socialAlertNewSince(newSinceCount),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: unreviewed ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
