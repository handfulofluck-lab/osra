import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers/world_class_provider.dart';

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
    final summary = ref.watch(reportSummaryProvider((childId: widget.childId, days: _days)));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
              ],
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
            ),
          ),
        ),
      ),
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load report: $e')),
        data: (data) => data.isEmpty
            ? Center(child: Text('No activity recorded in the last $_days days'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _UsageSection(summary: data, days: _days),
                  const SizedBox(height: 16),
                  _WebSection(summary: data),
                  const SizedBox(height: 16),
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
    final avg = days > 0 ? (summary.totalAppMinutes / days).round() : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('App usage', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Total ${summary.totalAppMinutes} min · avg $avg min/day'),
        if (summary.topApps.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('No app usage recorded'),
          )
        else ...[
          const SizedBox(height: 12),
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
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            name.length > 8 ? '${name.substring(0, 8)}…' : name,
                            style: const TextStyle(fontSize: 10),
                          ),
                        );
                      },
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Web', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('${summary.urlVisits} URL visits'),
        const SizedBox(height: 8),
        if (summary.topBlockedDomains.isEmpty)
          const Text('No blocked domains')
        else
          for (final d in summary.topBlockedDomains)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.block, size: 16),
              title: Text(d.domain),
              trailing: Text('${d.count}× blocked'),
            ),
        const SizedBox(height: 8),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('YouTube search is forced to SafeSearch'),
            subtitle: Text('Restricted Mode needs HTTPS inspection on the child PC (see guide)'),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Social & communication', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.flag_outlined, size: 14),
              label: Text('${summary.socialConcerns} social concerns'),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.call_outlined, size: 14),
              label: Text('${summary.calls} calls'),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.sms_outlined, size: 14),
              label: Text('${summary.sms} SMS'),
            ),
          ],
        ),
      ],
    );
  }
}
