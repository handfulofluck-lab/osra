import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../api/permission_errors.dart';

/// Feature #4: per-child activity report — app-usage bar chart, web stats
/// (visits + top blocked domains, with the YouTube SafeSearch NOTE #7) and
/// social/call/SMS summary chips, over a selectable 7/30-day window.
class ReportsScreen extends ConsumerStatefulWidget {
  final String childId;
  const ReportsScreen({super.key, required this.childId});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final summary = ref.watch(reportSummaryProvider((childId: widget.childId, days: _days)));
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.reportsTitle),
        actions: [
          // Roadmap 3.5: the summary here is top-apps only; the durable
          // per-day trend and the browsing history live on their own screen.
          IconButton(
            key: const ValueKey('usageHistoryButton'),
            tooltip: l10n.screenTimeWebHistoryTooltip,
            icon: const Icon(Icons.show_chart),
            onPressed: () => context.push('/child/${widget.childId}/history'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 7, label: Text(l10n.sevenDays)),
                ButtonSegment(value: 30, label: Text(l10n.thirtyDays)),
              ],
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
            ),
          ),
        ),
      ),
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(readErrorText(l10n, e, () => l10n.reportLoadFailed('$e')))),
        data: (data) => data.isEmpty
            ? Center(child: Text(l10n.noActivityDays(_days)))
            : ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  _UsageSection(summary: data, days: _days),
                  const SizedBox(height: AppSpace.lg),
                  _WebSection(summary: data),
                  const SizedBox(height: AppSpace.lg),
                  _SocialSection(summary: data),
                ],
              ),
      ),
    );
  }
}

/// App usage: total + average text and a bar chart of the top apps (minutes).
class _UsageSection extends StatelessWidget {
  final ReportSummary summary;
  final int days;
  const _UsageSection({required this.summary, required this.days});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final avg = days > 0 ? (summary.totalAppMinutes / days).round() : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.appUsage, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        Text(l10n.totalAverage(summary.totalAppMinutes, avg)),
        if (summary.topApps.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.md),
            child: Text(l10n.noAppUsage),
          )
        else ...[
          const SizedBox(height: AppSpace.md),
          SizedBox(
            // NOTE: fixed height — BarChart throws inside an unbounded height.
            height: 200,
            child: BarChart(
              key: const ValueKey('usageBarChart'),
              BarChartData(
                barGroups: [
                  for (var i = 0; i < summary.topApps.length; i++)
                    BarChartGroupData(x: i, barRods: [BarChartRodData(toY: summary.topApps[i].minutes.toDouble(), width: 18)]),
                ],
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, _) {
                        final i = value.toInt();
                        if (i < 0 || i >= summary.topApps.length) return const SizedBox.shrink();
                        // NOTE: shortened label — long app names overflow narrow screens.
                        final name = summary.topApps[i].name;
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Text(
                            name.length > 8 ? '${name.substring(0, 8)}…' : name,
                            style: AppType.chartTick,
                          ),
                        );
                      },
                    ),
                  ),
                  // NOTE: the default left axis drew bare minute numbers with no
                  // unit — an unexplained "120" next to the tallest bar. Label
                  // the ticks with the minute unit so the value is self-describing.
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 64,
                      getTitlesWidget: (value, _) => value <= 0
                          ? const SizedBox.shrink()
                          : Text(
                              l10n.minutesShort(value.toInt()),
                              style: AppType.chartTick,
                              textAlign: TextAlign.center,
                            ),
                    ),
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Web activity: total URL visits, top blocked domains and the YouTube
/// SafeSearch NOTE (#7 — pure copy, no behavior).
class _WebSection extends StatelessWidget {
  final ReportSummary summary;
  const _WebSection({required this.summary});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.webSection, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        Text(l10n.urlVisits(summary.urlVisits)),
        const SizedBox(height: AppSpace.sm),
        if (summary.topBlockedDomains.isEmpty)
          Text(l10n.noBlockedDomains)
        else
          for (final d in summary.topBlockedDomains)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.block, size: 16),
              title: Text(d.domain),
              trailing: Text(l10n.blockedTimes(d.count)),
            ),
        const SizedBox(height: AppSpace.sm),
        Card(
          color: context.tokens.surfaceVariant,
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.safeSearchForced),
            subtitle: Text(l10n.restrictedModeNote),
          ),
        ),
      ],
    );
  }
}

/// Social-monitoring concerns plus call/SMS counts as compact chips.
class _SocialSection extends StatelessWidget {
  final ReportSummary summary;
  const _SocialSection({required this.summary});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.socialAndCommunication, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          children: [
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.flag_outlined, size: 14),
              label: Text(l10n.socialConcerns(summary.socialConcerns)),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.call_outlined, size: 14),
              label: Text(l10n.callsCount(summary.calls)),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.sms_outlined, size: 14),
              label: Text(l10n.smsCount(summary.sms)),
            ),
          ],
        ),
      ],
    );
  }
}
