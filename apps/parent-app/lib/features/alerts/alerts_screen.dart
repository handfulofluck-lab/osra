import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;

import '../../api/permission_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../core/date_formatting.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../children/child_detail_screen.dart' show AlertTile;
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';
import '../../widgets/error_retry_view.dart';
import 'alert_detail_screen.dart';
import 'app_alert_presentation.dart';
import 'sos_alert_actions.dart';
import '../map/family_map_screen.dart'
    show FamilyMapScreen, MapFocus, mapIsAvailable;
import '../../push/sos_fix_text.dart';

/// U45: formats the alert detail dialog timestamp using the #889 time keys
/// (`alertAtTime`, `alertYesterdayAtTime`, `alertOnDateAtTime`), 24-hour
/// `HH:mm` without seconds, Western `0-9` digits, and LRI/PDI isolation.
@visibleForTesting
String formatAlertDetailTime(
  DateTime createdAt, {
  required AppLocalizations l10n,
  required String localeName,
  DateTime? now,
}) {
  final localTime = createdAt.toLocal();
  final refLocal = (now ?? DateTime.now()).toLocal();
  final localDay = DateTime.utc(localTime.year, localTime.month, localTime.day);
  final today = DateTime.utc(refLocal.year, refLocal.month, refLocal.day);
  final yesterday =
      DateTime.utc(refLocal.year, refLocal.month, refLocal.day - 1);

  final clock = normalizeDigits(DateFormat('HH:mm', 'en').format(localTime));
  final isolatedClock = ltrIsolate(clock);

  if (localDay == today) {
    return l10n.alertAtTime(isolatedClock);
  }
  if (localDay == yesterday) {
    return l10n.alertYesterdayAtTime(isolatedClock);
  }
  final isArabic = localeName.toLowerCase().startsWith('ar');
  final sameYear = localTime.year == refLocal.year;
  final pattern = isArabic
      ? (sameYear ? 'd MMMM' : 'd MMMM y')
      : (sameYear ? 'd MMM' : 'd MMM y');
  final resolvedLocale = DateFormat.localeExists(localeName)
      ? localeName
      : (isArabic ? 'ar' : 'en');
  final dateLabel = normalizeDigits(
    DateFormat(pattern, resolvedLocale).format(localTime),
  );
  return l10n.alertOnDateAtTime(dateLabel, isolatedClock);
}

/// #1029: Returns true when [incoming] is a stale aggregate snapshot of [existing]
/// (e.g. an older periodic-refresh response arriving after a newer realtime update).
bool _isStaleSocialAggregate(Alert existing, Alert incoming) {
  if (!existing.isSocialAlert || !incoming.isSocialAlert) return false;
  if (incoming.socialMessageCount < existing.socialMessageCount) return true;
  if (incoming.socialMessageCount == existing.socialMessageCount) {
    final prevTs = existing.effectiveTimestamp;
    final nextTs = incoming.effectiveTimestamp;
    if (prevTs != null && nextTs != null && nextTs.isBefore(prevTs)) {
      return true;
    }
  }
  return false;
}

/// #1029: Upserts [incoming] alerts into [existing] by `id` (never duplicating a card),
/// reconciles social aggregate versions by freshness so out-of-order responses never roll
/// a contact card backwards, and sorts descending by [Alert.effectiveTimestamp] so an alert
/// updated in place during a throttle window moves to the top of the feed.
List<Alert> mergeAlertsInPlace(List<Alert> existing, Iterable<Alert> incoming) {
  final byId = <String, Alert>{
    for (final a in existing) a.id: a,
  };
  for (final a in incoming) {
    final prev = byId[a.id];
    if (prev != null && _isStaleSocialAggregate(prev, a)) continue;
    if (prev != null &&
        prev.requestedScreenTimeMinutes != null &&
        prev.acknowledged &&
        (!a.acknowledged ||
            (prev.timeRequestResolution != null &&
                a.timeRequestResolution == null))) {
      continue;
    }
    final earlierReceipt = prev?.timeRequestResolution;
    final nextReceipt = a.timeRequestResolution;
    byId[a.id] = earlierReceipt?.decidedByViewer == true &&
            nextReceipt != null &&
            nextReceipt.decidedByViewer == null &&
            earlierReceipt!.resolvedAt == nextReceipt.resolvedAt
        ? a.copyWith(timeRequestResolution: earlierReceipt)
        : a;
  }
  final merged = byId.values.toList();
  merged.sort((a, b) {
    final aPinned = isParentDecisionAlert(a) && !a.acknowledged;
    final bPinned = isParentDecisionAlert(b) && !b.acknowledged;
    if (aPinned != bPinned) return aPinned ? -1 : 1;
    final ta = a.effectiveTimestamp;
    final tb = b.effectiveTimestamp;
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  });
  return merged;
}

/// Alerts feed: grouped by day, severity-colored, swipe-to-acknowledge with
/// optimistic removal, detail dialog per category, and paged "load more".
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({
    super.key,
    @visibleForTesting this.nowProvider,
    @visibleForTesting this.liveRefreshInterval = const Duration(seconds: 30),
  });

  final DateTime Function()? nowProvider;

  /// #1029: bounded live refresh interval while the feed is open so running counts
  /// update in place without requiring a pull-to-refresh gesture.
  final Duration liveRefreshInterval;

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final List<Alert> _items = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _liveRefreshing = false;
  Timer? _liveRefreshTimer;
  String? _error;

  /// A read this guardian's invite does not cover (ADR-0014 amendment, decision 7). Kept apart
  /// from [_error] so the screen names the fix instead of printing "failed to load".
  ReadPermissionRequired? _refused;

  @override
  void initState() {
    super.initState();
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

  /// #1029: silent bounded page-1 refresh so an open feed updates running counts,
  /// moves updated cards to the top, and shows "+N new" without a manual gesture.
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
        final merged = mergeAlertsInPlace(_items, pageData.items);
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
      final pageData = AlertsPage.fromJson(res.data);
      final isFirstPage = _page == 0;
      setState(() {
        _page++;
        // #1029: upsert by id and sort by effectiveTimestamp desc so in-place
        // updated social alerts refresh their count and move to the top without duplicating.
        final merged = mergeAlertsInPlace(_items, pageData.items);
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
                context.l10n, e, () => context.l10n.alertsLoadFailed)
            : null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _ack(Alert alert, int index) async {
    // Optimistic removal; reinsert on failure.
    setState(() => _items.removeAt(index));
    try {
      await ref.read(apiClientProvider).raw.post('/v1/alerts/${alert.id}/ack');
      ref.read(alertsSeenProvider.notifier).markAcknowledged(alert.id);
      ref.invalidate(unacknowledgedAlertsProvider);
      ref.invalidate(unacknowledgedCountProvider);
    } on DioException catch (e) {
      setState(() => _items.insert(index, alert));
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(
              context.l10n, e, () => context.l10n.acknowledgeFailed),
          onRetry: () => _ack(alert, index),
        );
      }
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
    final merged = mergeAlertsInPlace(_items, [updated]);
    setState(() {
      _items
        ..clear()
        ..addAll(merged);
    });
  }

  /// Feature #8: an install_request alert offers Block (append a block
  /// appRule to the child's ruleset) and Allow (just dismiss) actions.
  void _showDetail(Alert alert) {
    // #972: social/gaming chat alerts open the dedicated full-screen scrollable detail route
    // so 200% text size, authorized Social activity action, and unavailable-preview states stay accessible.
    if (isSocialAlertCategory(alert.category)) {
      // #1029: opening the social alert clears any "+N new" badge until more messages arrive.
      ref.read(alertsSeenProvider.notifier).markAlertOpened(alert);
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
      return;
    }
    if (alert.category == 'app_blocked') {
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
      return;
    }
    // Feature #16: conversation-coach card for AI/social alert categories.
    final coachCard = coachCardFor(alert.category, _concernTypesOf(alert));
    showDialog(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        return AlertDialog(
          scrollable: true,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          title: Row(
            children: [
              Icon(Icons.circle,
                  size: 12,
                  color:
                      AlertTile.severityColor(alert.severity, dialogContext)),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                  child: Text(
                      l10n.alertTitleFor(alert.category, alert.title,
                          isEnglish: dialogContext.localeName.startsWith('en'),
                          tamperType: alert.metadata['type']?.toString()),
                      style: Theme.of(dialogContext).textTheme.titleMedium)),
            ],
          ),
          content: Consumer(
            builder: (dialogContext, dialogRef, _) {
              final childName = dialogRef
                  .watch(familyProvider)
                  .valueOrNull
                  ?.children
                  .where((c) => c.id == alert.childId)
                  .firstOrNull
                  ?.displayName;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // #1128: an alert is not a rule change, so no RulesBehindBanner belongs here.
                  // #755 Arabic Bureau (6868533968): SOS already states the event in its localized title and
                  // place lines, so never repeat the child agent's raw English sentence.
                  // #889 Arabic Bureau (6997818132): an unkeyed restart row in Arabic renders no body at all
                  // inside the app dialog (the title already states it), never raw English or the push prompt.
                  Builder(builder: (_) {
                    final localizedBody = formatGeneralAlertBody(
                      alert,
                      l10n: l10n,
                      localeName: dialogContext.localeName,
                      now: widget.nowProvider?.call(),
                    );
                    if (localizedBody.isEmpty) return const SizedBox.shrink();
                    return Text(localizedBody);
                  }),
                  // #672: where, in words and in the Bureau's sentence, in the alert the parent opened
                  // deliberately — the lock screen carries neither. The coordinates are isolated (LRI/PDI)
                  // so they keep their order in Arabic; the accuracy clause only when the fix has one.
                  if (alert.category == 'sos' && alert.location != null) ...[
                    const SizedBox(height: AppSpace.sm),
                    Builder(builder: (_) {
                      final fix = alert.location!;
                      final text = SosFixText.of(alert, fix, DateTime.now());
                      final accuracy = text.accuracyClause(l10n, fix);
                      return Column(
                        key: const ValueKey('alert-sos-location'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // #743 UI/UX: the place is a sentence a parent reads, so it takes the dialog's
                          // default body style — the same weight as the alert's own body. Only the accuracy
                          // is a detail, and it stays small and muted under it.
                          Text(
                            text.locationLine(l10n, fix.isolatedCoords),
                            key: const ValueKey('alert-sos-location-line'),
                          ),
                          if (accuracy != null)
                            Text(accuracy,
                                style: Theme.of(dialogContext)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(dialogContext).hintColor,
                                    )),
                        ],
                      );
                    }),
                  ],
                  // #444: the agent cannot end another app's VoIP call, so this alert must say the call
                  // kept going rather than let the parent assume the block ended it. Only for the call
                  // layout: a split-screen or PiP bypass already reads correctly from the body.
                  if (alert.category == 'tamper' &&
                      alert.metadata['type']?.toString() == 'block_bypass' &&
                      alert.metadata['layout']?.toString() == 'call') ...[
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      l10n.alertCallBypassNote,
                      key: const ValueKey('alert-call-bypass-note'),
                      style: Theme.of(dialogContext)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                    ),
                  ],
                  const SizedBox(height: AppSpace.sm),
                  if (childName != null && childName.isNotEmpty)
                    Text(l10n.alertChildLabel(childName)),
                  Text(l10n.categoryLabel(l10n.alertCategory(alert.category))),
                  if (alert.createdAt != null)
                    Text(
                      l10n.alertDetailSent(
                        formatAlertDetailTime(
                          alert.createdAt!,
                          l10n: l10n,
                          localeName: dialogContext.localeName,
                          now: widget.nowProvider?.call(),
                        ),
                      ),
                      key: const ValueKey('alert-detail-time'),
                    ),
                  const Divider(),
                  CoachCardSection(card: coachCard, compact: true),
                ],
              );
            },
          ),
          actions: [
            if (alert.category == 'install_request') ...[
              OutlinedButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(l10n.allowedSnack)));
                },
                child: Text(l10n.allowAction),
              ),
              FilledButton(
                onPressed: () => _blockRequestedApp(dialogContext, alert),
                child: Text(l10n.blockThisApp),
              ),
            ],
            // #672 UI/UX: an SOS that carried a fix gets one tap to the place, on the same family map the
            // tab shows. One **filled** button, and it is the one that works (#743 UI/UX review): on a build
            // #672/#743 UI/UX: the one filled button is the one that works, and the stacked order is set in
            // sosAlertActions rather than inherited from the action row. That file carries the why.
            if (alert.category == 'sos' && alert.location != null)
              ...sosAlertActions(
                l10n: l10n,
                mapAvailable: mapIsAvailable(Theme.of(dialogContext).platform),
                onShowOnMap: () {
                  final fix = alert.location!;
                  final text = SosFixText.of(alert, fix, DateTime.now());
                  final title = l10n.alertTitleFor(
                    alert.category,
                    alert.title,
                    isEnglish: dialogContext.localeName.startsWith('en'),
                  );
                  Navigator.of(dialogContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FamilyMapScreen(
                        focus: MapFocus.fromFix(
                          fix,
                          label: text.pinCaption(l10n, title),
                          accuracyM: fix.accuracyM,
                        ),
                      ),
                    ),
                  );
                },
                onOpenInMaps: () => _openInMaps(alert),
                onCopy: () async {
                  await Clipboard.setData(
                      ClipboardData(text: alert.location!.copyText));
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.alertCoordinatesCopied)),
                  );
                },
              ),
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l10n.close)),
          ],
        );
      },
    );
  }

  /// #672 UI/UX: hand the fix to the phone's own maps app. `geo:` is Android's, `maps.apple.com` is iOS's,
  /// and both render a place name we cannot — which is the point of the fallback.
  Future<void> _openInMaps(Alert alert) async {
    final fix = alert.location;
    if (fix == null) return;
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final label = Uri.encodeComponent(fix.copyText);
    final uri = isAndroid
        ? Uri.parse('geo:${fix.lat},${fix.lng}?q=${fix.lat},${fix.lng}($label)')
        : Uri.parse(
            'https://maps.apple.com/?ll=${fix.lat},${fix.lng}&q=$label');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A phone with no maps app: the copy button above is the remaining route, and it is always there.
    }
  }

  /// Metadata `concernTypes` of a social_concern alert, normalized to strings.
  List<String> _concernTypesOf(Alert alert) {
    final raw = alert.metadata['concernTypes'];
    if (raw is List) return [for (final t in raw) '$t'];
    return const [];
  }

  /// Appends `{packageId, appName, action: 'block'}` to the child's appRules
  /// (preserving everything else the ruleset carries, incl. always-allowed).
  Future<void> _blockRequestedApp(
      BuildContext dialogContext, Alert alert) async {
    final l10n = context.l10n;
    final api = ref.read(apiClientProvider).raw;
    try {
      final res = await api.get('/v1/rules/${alert.childId}');
      final ruleSet =
          RuleSet.fromJson(Map<String, dynamic>.from(res.data as Map));
      final body = ruleSet.toJson();
      final pkg = '${alert.metadata['packageId'] ?? ''}'.trim();
      if (pkg.isEmpty)
        throw StateError('install_request alert has no packageId');
      (body['appRules'] as List).add({
        'packageId': pkg,
        'appName': '${alert.metadata['appName'] ?? pkg}',
        'action': 'block',
      });
      await api.put('/v1/rules/${alert.childId}', data: body);
      ref.invalidate(alertsProvider);
      ref.invalidate(rulesProvider(alert.childId));
      // Issue #475 follow-up: this screen writes rules, so the family snapshot must be refetched —
      // otherwise right after a save the app believes `applied == rules` and the "not picked up yet"
      // line never appears at the moment it is earned (#501 review).
      ref.invalidate(familyProvider);
      if (!dialogContext.mounted) return;
      Navigator.of(dialogContext).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.appBlockedSnack)));
    } catch (e) {
      if (dialogContext.mounted) {
        showErrorSnackBar(
          dialogContext,
          friendlyErrorText(l10n, e, () => l10n.blockFailed),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final seen = ref.watch(alertsSeenProvider);
    // #1029: when the realtime /v1/ws alert invalidation path reloads alertsProvider,
    // merge the fresh page into the open feed immediately without requiring a gesture.
    ref.listen<AsyncValue<AlertsPage>>(alertsProvider(const AlertFilter()),
        (prev, next) {
      if (next is! AsyncData<AlertsPage> || !mounted || _items.isEmpty) return;
      final page = next.value;
      setState(() {
        final merged = mergeAlertsInPlace(_items, page.items);
        _items
          ..clear()
          ..addAll(merged);
      });
    });
    final pinned = _items
        .where((alert) => isParentDecisionAlert(alert) && !alert.acknowledged)
        .toList();
    // Group the remainder by local day; unanswered requests stay ahead of every day header.
    final groups = <String, List<Alert>>{};
    final order = <String>[];
    for (final a in _items) {
      if (pinned.any((request) => request.id == a.id)) continue;
      final ts = a.effectiveTimestamp;
      final day = ts == null ? 'Unknown' : dayKey(ts.toLocal());
      if (!groups.containsKey(day)) {
        groups[day] = [];
        order.add(day);
      }
      groups[day]!.add(a);
    }
    order.sort((a, b) => b.compareTo(a));

    Widget alertCard(Alert alert) {
      final index = _items.indexOf(alert);
      final tile = AlertTile(
        alert: alert,
        newSinceCount: computeSocialNewSinceCount(alert, seen),
        onRequestResolved: (resolution, at) =>
            _requestResolved(alert, resolution, at),
        onTimeRequestResolved: _mergeRequestResolution,
        onTap: () => _showDetail(alert),
      );
      if (alert.requestedScreenTimeMinutes != null) return tile;
      return Dismissible(
        key: ValueKey(alert.id),
        background: Container(
          color: context.tokens.ok,
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsetsDirectional.only(start: AppSpace.xl),
          child: Icon(Icons.check, color: context.tokens.onOk),
        ),
        onDismissed: (_) => _ack(alert, index),
        child: tile,
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.alertsTitle)),
      body: _refused != null && _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.readPermissionRequired,
                    textAlign: TextAlign.center),
              ),
            )
          : _error != null && _items.isEmpty
              ? ErrorRetryView(message: _error!, onRetry: _loadMore)
              : RefreshIndicator(
                  onRefresh: () async {
                    setState(() {
                      _items.clear();
                      _page = 0;
                      _hasMore = true;
                    });
                    await _loadMore();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: AppSpace.xl),
                    children: [
                      // NOTE: explicit empty state — without it an empty feed was a blank screen.
                      // 200 is a deliberate vertical centring offset, not a gap on the scale.
                      if (_items.isEmpty && !_loading)
                        Padding(
                          padding: const EdgeInsets.only(top: 200),
                          child: Center(child: Text(l10n.noAlertsYet)),
                        ),
                      for (final alert in pinned) alertCard(alert),
                      for (final day in order)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(
                                  AppSpace.lg,
                                  AppSpace.lg,
                                  AppSpace.lg,
                                  AppSpace.xs),
                              child: Text(
                                _dayLabel(context, day),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            for (final alert in groups[day]!) alertCard(alert),
                          ],
                        ),
                      if (_loading)
                        const Padding(
                            padding: EdgeInsets.all(AppSpace.lg),
                            child: Center(child: CircularProgressIndicator())),
                      if (!_loading && _hasMore)
                        Center(
                          child: TextButton(
                              onPressed: _loadMore, child: Text(l10n.loadMore)),
                        ),
                    ],
                  ),
                ),
    );
  }

  String _dayLabel(BuildContext context, String key) {
    if (key == 'Unknown') return context.l10n.unknown;
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    return formatDayHeader(d, context.localeName);
  }
}
