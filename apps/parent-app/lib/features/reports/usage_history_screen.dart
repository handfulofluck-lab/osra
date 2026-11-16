import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../api/permission_errors.dart';

/// Roadmap 3.5: the durable usage model in the parent app. One screen carries
/// both reads, because they share the 7/14/30-day window:
///
///  - `GET /v1/reports/usage` — per-day screen time from `AppUsageDaily`
///    (`UsageDay`), drawn as a bar per returned day plus a readable per-day list.
///  - `GET /v1/reports/web` — `WebVisit` rows, newest first, with a blocked-only
///    filter and a limit (the endpoint has no offset, so limit is the paging control).
///
/// The API fills every requested day with 0 when there are no rows, so this
/// screen never pads: it draws exactly `series.length` bars and says so when a
/// shorter series than requested arrives.
class UsageHistoryScreen extends ConsumerStatefulWidget {
  final String childId;
  const UsageHistoryScreen({super.key, required this.childId});

  @override
  ConsumerState<UsageHistoryScreen> createState() => _UsageHistoryScreenState();
}

class _UsageHistoryScreenState extends ConsumerState<UsageHistoryScreen> {
  int _days = 7;
  bool _blockedOnly = false;
  int _limit = 20;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.screenTimeWebTitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            // NOTE: three full English labels ("7 days"/"14 days"/"30 days")
            // overflow a 320px-wide AppBar, so the labels come from the short
            // day forms in the ARB (English "{days}d"; Arabic full-word plurals).
            child: SegmentedButton<int>(
              key: const ValueKey('usageWindowSelector'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 7, label: Text(l10n.daysShort(7))),
                ButtonSegment(value: 14, label: Text(l10n.daysShort(14))),
                ButtonSegment(value: 30, label: Text(l10n.daysShort(30))),
              ],
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _UsageSection(childId: widget.childId, days: _days),
          const SizedBox(height: AppSpace.lg),
          _BrowsingSection(
            childId: widget.childId,
            days: _days,
            blockedOnly: _blockedOnly,
            limit: _limit,
            onBlockedChanged: (v) => setState(() => _blockedOnly = v),
            onLimitChanged: (v) => setState(() => _limit = v),
          ),
        ],
      ),
    );
  }
}

/// Screen time: honest total, bar chart and a per-day list. The header is
/// outside the async body so it does not move while the request is in flight;
/// the loading placeholder reserves the chart's height.
class _UsageSection extends ConsumerWidget {
  final String childId;
  final int days;
  const _UsageSection({required this.childId, required this.days});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final query = (childId: childId, days: days);
    final report = ref.watch(usageReportProvider(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.screenTime, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.sm),
        report.when(
          loading: () => const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator(key: ValueKey('usageLoading'))),
          ),
          error: (e, _) => _ErrorBody(
            message: l10n.couldNotLoadScreenTime,
            detail: '$e',
            onRetry: () => ref.invalidate(usageReportProvider(query)),
          ),
          data: (data) => _UsageBody(report: data, requestedDays: days),
        ),
      ],
    );
  }
}

class _UsageBody extends StatelessWidget {
  final UsageReport report;
  final int requestedDays;
  const _UsageBody({required this.report, required this.requestedDays});

  static String _dayLabel(String day, String locale) {
    final date = DateTime.tryParse(day);
    // Locale-aware skeleton (not a fixed "MMM d" pattern) so Arabic keeps the
    // day-before-month order, matching the DateFormat.MMMd used in the web list.
    return date == null ? day : DateFormat.MMMEd(locale).format(date);
  }

  static String _shortDay(String day, String locale) {
    final date = DateTime.tryParse(day);
    return date == null ? day : DateFormat.MMMd(locale).format(date);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final locale = context.localeName;
    final series = report.series;
    final total = report.seriesMinutes;
    if (series.isEmpty) {
      return _EmptyBody(text: l10n.noScreenTimeData(requestedDays));
    }
    if (total == 0) {
      return _EmptyBody(text: l10n.noScreenTimeRecorded(requestedDays));
    }
    final maxMinutes = series.fold<int>(0, (m, d) => d.minutes > m ? d.minutes : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.totalOverDays(total, series.length)),
        if (series.length < requestedDays)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Text(
              l10n.fewerDaysReturned(series.length, requestedDays),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: AppSpace.md),
        // NOTE: bars are plain Containers — no charting dependency, and no
        // fixed-width tick labels that would overflow 30 bars at 320px.
        SizedBox(
          key: const ValueKey('usageChart'),
          height: 160,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final day in series)
                Expanded(
                  child: Tooltip(
                    message: l10n.dayTooltip(_dayLabel(day.day, locale), day.minutes),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: UsageBar(
                        key: ValueKey('usageBar-${day.day}'),
                        day: day.day,
                        minutes: day.minutes,
                        maxMinutes: maxMinutes,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(_shortDay(series.first.day, locale)), Text(_shortDay(series.last.day, locale))],
        ),
        const Divider(height: AppSpace.xl),
        Text(l10n.dayByDay, style: Theme.of(context).textTheme.titleSmall),
        // NOTE: every returned day is listed, including 0-minute days, so the
        // list stays honest when the chart is too small to read.
        for (final day in series.reversed)
          ListTile(
            key: ValueKey('usageDay-${day.day}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_dayLabel(day.day, locale)),
            trailing: Text(l10n.minutesShort(day.minutes)),
          ),
      ],
    );
  }
}

/// One day's bar: height is proportional to the window's busiest day.
///
/// Public so widget tests can count the rendered days — the count is the
/// evidence that no zero padding was added in the client.
class UsageBar extends StatelessWidget {
  final String day;
  final int minutes;
  final int maxMinutes;
  const UsageBar({super.key, required this.day, required this.minutes, required this.maxMinutes});

  static const _maxHeight = 120.0;

  @override
  Widget build(BuildContext context) {
    final factor = maxMinutes <= 0 ? 0.0 : minutes / maxMinutes;
    return Container(
      height: _maxHeight * factor,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: context.tokens.primary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.xs)),
      ),
    );
  }
}

/// Browsing history: blocked-only filter, limit control, and one row per visit.
class _BrowsingSection extends ConsumerWidget {
  final String childId;
  final int days;
  final bool blockedOnly;
  final int limit;
  final ValueChanged<bool> onBlockedChanged;
  final ValueChanged<int> onLimitChanged;

  const _BrowsingSection({
    required this.childId,
    required this.days,
    required this.blockedOnly,
    required this.limit,
    required this.onBlockedChanged,
    required this.onLimitChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final query = (childId: childId, days: days, blockedOnly: blockedOnly, limit: limit);
    final visits = ref.watch(webHistoryProvider(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.browsingHistory, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        // NOTE: Wrap, not Row — filter + limit control do not fit one line at
        // 320px and must wrap instead of overflowing.
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              key: const ValueKey('blockedOnlyFilter'),
              label: Text(l10n.blockedOnly),
              selected: blockedOnly,
              onSelected: onBlockedChanged,
            ),
            Text(l10n.showLabel),
            SegmentedButton<int>(
              key: const ValueKey('webLimitSelector'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 20, label: Text('20')),
                ButtonSegment(value: 50, label: Text('50')),
                ButtonSegment(value: 100, label: Text('100')),
              ],
              selected: {limit},
              onSelectionChanged: (s) => onLimitChanged(s.first),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        visits.when(
          loading: () => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(key: ValueKey('webLoading'))),
          ),
          // ADR-0014 decision 7 (#406): a refusal says so and drops the raw DioException detail, so the
          // owner sentence is not followed by "DioException [bad response]: ...".
          error: (e, _) => _ErrorBody(
            message: readErrorText(l10n, e, () => l10n.couldNotLoadBrowsing),
            detail: ReadPermissionRequired.isRefusal(e) ? '' : '$e',
            onRetry: () => ref.invalidate(webHistoryProvider(query)),
          ),
          data: (items) {
            if (items.isEmpty) {
              return _EmptyBody(
                text: blockedOnly
                    ? l10n.noBlockedSites(days)
                    : l10n.noBrowsingHistory(days),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (items.length >= limit)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.xs),
                    child: Text(
                      l10n.showingLatestVisits(limit),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                for (final visit in items) _WebVisitTile(visit: visit),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _WebVisitTile extends StatelessWidget {
  final WebVisit visit;
  const _WebVisitTile({required this.visit});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l10n = context.l10n;
    final when = visit.ts == null
        ? l10n.timeUnknown
        : DateFormat.MMMd(context.localeName).add_Hm().format(visit.ts!.toLocal());
    return ListTile(
      key: ValueKey('webVisit-${visit.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        visit.blocked ? Icons.block : Icons.public,
        size: 18,
        color: visit.blocked ? tokens.danger : null,
      ),
      title: Text(visit.domain, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(when),
      trailing: Text(
        visit.blocked ? l10n.blocked : l10n.allowed,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: visit.blocked ? tokens.danger : tokens.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  final String text;
  const _EmptyBody({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      child: Text(text),
    );
  }
}

/// Error body with the action that retries the same query. [detail] is the
/// raw exception so a 403/500 is visible, not hidden behind a friendly line.
class _ErrorBody extends StatelessWidget {
  final String message;
  final String detail;
  final VoidCallback onRetry;
  const _ErrorBody({required this.message, required this.detail, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A refusal passes an empty detail: the message is the whole sentence, and appending a stray
          // colon to it would look like a truncation bug.
          Text(detail.isEmpty ? message : '$message: $detail'),
          const SizedBox(height: AppSpace.xs),
          TextButton(onPressed: onRetry, child: Text(context.l10n.tryAgain)),
        ],
      ),
    );
  }
}
