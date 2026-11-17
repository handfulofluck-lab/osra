import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../core/ltr_isolate.dart';
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

/// "Total X · avg Y" on one line when it fits, two lines when it does not.
///
/// #841 Arabic Language Bureau (22:22Z): at 320 px / 200 % the average wrapped and left the separator at
/// the end of the first line — «الإجمالي: 315 دقيقة ·» — and in RTL a dot at the end of a line reads as a
/// stray mark. So the separator is only drawn when both halves share the line; otherwise the two halves
/// are two lines and there is no dot. The halves come from the localized string itself (split on the
/// separator glyph both locales use), so no new string had to be authored for this.
class _TotalAndAverage extends StatelessWidget {
  final int total;
  final int avg;
  const _TotalAndAverage({required this.total, required this.avg});

  static final _separator = RegExp(r'\s*\u00B7\s*');

  /// The two halves of the localized line, or null when the string has no separator at all.
  static (String, String)? halves(String combined) {
    final parts = combined.split(_separator);
    if (parts.length < 2) return null;
    return (parts.first.trim(), parts.sublist(1).join(' \u00B7 ').trim());
  }

  @override
  Widget build(BuildContext context) {
    final combined = context.l10n.totalAverage(total, avg);
    final split = halves(combined);
    if (split == null) return Text(combined);
    final (left, right) = split;
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style;
        final scaler = MediaQuery.textScalerOf(context);
        bool fits(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1,
          )..layout(maxWidth: constraints.maxWidth);
          return !painter.didExceedMaxLines;
        }

        // Mutant: always return the single Text, and the Arabic frame ends its first line on «·» again.
        if (fits(combined)) return Text(combined);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(left), Text(right)],
        );
      },
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
        _TotalAndAverage(total: summary.totalAppMinutes, avg: avg),
        if (summary.topApps.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.md),
            child: Text(l10n.noAppUsage),
          )
        else ...[
          const SizedBox(height: AppSpace.md),
          TopAppsChart(apps: summary.topApps),
        ],
      ],
    );
  }
}

/// The top-apps bar chart, sized for the text scale it is drawn at.
///
/// #841 condition 4 (UI/UX Bureau). At 320 px with 200 % text the chart collided with itself in three
/// ways: the value axis reserved a fixed 64 px whatever the text size, every app name was cut to eight
/// characters with an ellipsis, and the labels had no width of their own to wrap into. The three fixes
/// are the three knobs: [tickIntervalFor] keeps the value axis to at most three labels,
/// [axisWidthFor] reserves what the widest label actually measures at this scale, and each bottom
/// label is given its own slot to wrap inside.
///
/// Public (like `UsageBar`) so a widget test can assert the two sizing rules directly instead of
/// guessing them from a screenshot.
class TopAppsChart extends StatelessWidget {
  final List<TopApp> apps;
  const TopAppsChart({super.key, required this.apps});

  /// Height of the plot alone; the labels strip is added to it in [build].
  static const double plotHeight = 140;

  /// The value the axis tops out at: the busiest app plus headroom, so the tallest bar is not flush
  /// with the top edge. Never 0 — fl_chart divides by the range.
  static double maxYFor(List<TopApp> apps) {
    final top = apps.fold<int>(0, (m, a) => a.minutes > m ? a.minutes : m);
    return top <= 0 ? 1 : top * 1.1;
  }

  /// The interval that draws **at most three** value labels (0 is not drawn), however tall the text.
  static double tickIntervalFor(List<TopApp> apps) => maxYFor(apps) / 2;

  /// The width the value axis needs for the widest label it will draw, measured rather than guessed:
  /// «210 دقائق» at 200 % is more than twice what "210 min" is at 100 %.
  static double axisWidthFor(BuildContext context, List<TopApp> apps) {
    final painter = TextPainter(
      text: TextSpan(
        text: context.l10n.minutesShort(maxYFor(apps).round()),
        style: AppType.chartTick,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width.ceilToDouble() + AppSpace.sm;
  }

  /// How many lines [name] needs at [width], capped at [maxLines]; measured with the chart's own face,
  /// because a widget test's font is not the handset's and a guess is not a layout.
  static int linesNeededFor(String name, double width, int maxLines, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: name, style: AppType.chartTick),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: maxLines,
    )..layout(maxWidth: width);
    if (!painter.didExceedMaxLines) {
      // The count is the number of line boxes the painter produced.
      final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: name.length));
      return boxes.map((b) => b.top.round()).toSet().length;
    }
    return maxLines + 1;
  }

  /// The gap between one label's slot and the next, so two neighbours never touch.
  static const double labelGap = 6;

  /// At most this many lines under a bar before the labels stop being readable as labels.
  static const int labelMaxLines = 3;

  /// Two lines of the tick face at the current scale, plus the gap above them.
  static double labelHeightFor(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(context).scale(AppType.chartTick.fontSize ?? 10);
    return scaled * 2 * (AppType.chartTick.height ?? 1.2) + AppSpace.xs;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final axisWidth = axisWidthFor(context, apps);
    final labelHeight = labelHeightFor(context);
    final interval = tickIntervalFor(apps);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Condition 4 (UI/UX Bureau, Codex's retake): the slot is the real bar spacing minus a gap, and the
        // names are measured rather than assumed to fit. Slots were `plotWidth / bars` with no gap, so with
        // 200 % text one label's last word sat against the next label's first — «FictionaReading».
        final slot = ((constraints.maxWidth - axisWidth) / apps.length) - labelGap;
        final widest = apps.fold<int>(1, (m, a) {
          final lines = linesNeededFor(a.name, slot, labelMaxLines, scaler);
          return lines > m ? lines : m;
        });
        // Condition 4's second half: "a readable full-name layout when labels do not fit". Under a bar there
        // is room for three lines and no more; beyond that the names move below the chart as a legend, where
        // every one is drawn whole and left to right instead of being shortened to fit a 30 px slot.
        final legend = widest > labelMaxLines;
        final legendHeight = legend ? _legendHeightFor(context) : 0.0;

        final chart = SizedBox(
          // NOTE: fixed height — BarChart throws inside an unbounded height. It grows with the label strip
          // so a 200 % text scale gets the room the labels need instead of squeezing the plot.
          height: plotHeight + (legend ? 0 : labelHeight),
          child: BarChart(
            key: const ValueKey('usageBarChart'),
            BarChartData(
              maxY: maxYFor(apps),
              barGroups: [
                for (var i = 0; i < apps.length; i++)
                  BarChartGroupData(x: i, barRods: [BarChartRodData(toY: apps[i].minutes.toDouble(), width: 18)]),
              ],
              titlesData: FlTitlesData(
                bottomTitles: legend
                    ? const AxisTitles(sideTitles: SideTitles(showTitles: false))
                    : AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: labelHeight,
                          getTitlesWidget: (value, _) {
                            final i = value.toInt();
                            if (i < 0 || i >= apps.length) return const SizedBox.shrink();
                            return SizedBox(
                              width: slot,
                              child: Padding(
                                padding: const EdgeInsets.only(top: AppSpace.xxs),
                                child: Text(
                                  // A Latin app name inside an Arabic chart needs its own first-strong
                                  // isolate, exactly as the host rows do (Arabic Language Bureau, 22:22Z).
                                  ltrIsolate(apps[i].name),
                                  style: AppType.chartTick,
                                  textAlign: TextAlign.center,
                                  maxLines: labelMaxLines,
                                  softWrap: true,
                                  overflow: TextOverflow.clip,
                                ),
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
                    reservedSize: axisWidth,
                    interval: interval,
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
              // Grid lines follow the same interval, so a line always means a label.
              gridData: FlGridData(horizontalInterval: interval),
              borderData: FlBorderData(show: false),
            ),
          ),
        );

        if (!legend) return chart;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            chart,
            SizedBox(height: legendHeight),
            for (final app in apps)
              Padding(
                key: ValueKey('usageChartLegend-${app.name}'),
                padding: const EdgeInsets.only(bottom: AppSpace.xxs),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: context.tokens.primary, borderRadius: BorderRadius.circular(2)),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        // The Bureau's condition on the legend: in Arabic the bars run right to left, so a
                        // top-to-bottom list is easy to map the wrong way round. The row carries its own
                        // minutes, so it identifies its bar by value rather than by position.
                        l10n.chartLegendRow(ltrIsolate(app.name), app.minutes),
                        style: AppType.chartTick,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// One wrapped line per legend row at the current scale, plus the gap above the list.
  static double _legendHeightFor(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(AppType.chartTick.fontSize ?? 10) *
          (AppType.chartTick.height ?? 1.2) +
      AppSpace.xs;
}

/// Web activity: sites visited, top blocked domains and the YouTube
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
        // #830: with site-name rows the card counts sites, not addresses; the Bureau issued this line for it
        // and it had no caller until now.
        Text(l10n.webSitesSummary(summary.urlVisits)),
        const SizedBox(height: AppSpace.sm),
        if (summary.topBlockedDomains.isEmpty)
          Text(l10n.noBlockedDomains)
        else
          for (final d in summary.topBlockedDomains) _BlockedDomainTile(domain: d.domain, count: d.count),
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

/// One blocked host and how often it was blocked.
///
/// #841 condition 5 (UI/UX Bureau): at a narrow width or a large text scale the count must sit on its
/// own line under the host instead of being a trailing column, where the two compete for the same
/// pixels and the host is the part that gets cut. The threshold is the same one the Bureau named —
/// a 320 px phone, or text over 130 % — and the host keeps the same full-text, break-at-dot treatment
/// as the history rows (#841 condition 2).
class _BlockedDomainTile extends StatelessWidget {
  final String domain;
  final int count;
  const _BlockedDomainTile({required this.domain, required this.count});

  /// The width and text scale at which the count stops fitting beside the host.
  static bool stacksAt(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 360 || MediaQuery.textScalerOf(context).scale(1) > 1.3;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stacks = stacksAt(context);
    return ListTile(
      key: ValueKey('blockedDomain-$domain'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.block, size: 16),
      title: Text(ltrIsolateHost(domain)),
      subtitle: stacks ? Text(l10n.blockedTimes(count)) : null,
      trailing: stacks ? null : Text(l10n.blockedTimes(count)),
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
