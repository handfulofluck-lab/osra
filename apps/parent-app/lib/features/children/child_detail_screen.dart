import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../dashboard/dashboard_screen.dart' show formatLastSeen;
import '../social/social_screen.dart' show SocialSectionsView;
import 'command_history_screen.dart' show commandStatusLabel, commandTypeLabel, formatCommandTime;

/// Per-child detail view with Overview / Apps / Social / Location / Alerts tabs.
class ChildDetailScreen extends ConsumerWidget {
  final String childId;
  const ChildDetailScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == childId).firstOrNull;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(child?.displayName ?? 'Child'),
          // NOTE: scrollable — five labels no longer fit at 320px width.
          bottom: const TabBar(
            isScrollable: true,
            tabs: [Tab(text: 'Overview'), Tab(text: 'Apps'), Tab(text: 'Social'), Tab(text: 'Location'), Tab(text: 'Alerts')],
          ),
          actions: [
            IconButton(
              tooltip: 'Reports',
              icon: const Icon(Icons.insights),
              onPressed: () => context.push('/child/$childId/reports'),
            ),
            IconButton(
              key: const ValueKey('searchSafetyButton'),
              tooltip: 'Search & web safety',
              icon: const Icon(Icons.saved_search_outlined),
              onPressed: () => context.push('/child/$childId/searches'),
            ),
            TextButton.icon(
              onPressed: () => context.push('/child/$childId/rules'),
              icon: const Icon(Icons.rule),
              label: const Text('Edit rules'),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _OverviewTab(childId: childId),
            _AppsTab(childId: childId),
            _SocialTab(childId: childId),
            _LocationTab(childId: childId),
            _AlertsTab(childId: childId),
          ],
        ),
      ),
    );
  }
}

class _OverviewTab extends ConsumerWidget {
  final String childId;
  const _OverviewTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == childId).firstOrNull;
    final devices = overview?.devicesFor(childId) ?? const <Device>[];
    final internetPaused = ref.watch(internetPausedProvider(childId)).valueOrNull ?? false;
    if (overview == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (child != null)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(child.initials)),
              title: Text(child.displayName),
              subtitle: Text('Born ${child.birthYear}'),
            ),
          ),
        // NOTE: simplest entry — the chevron jumps to the Social tab instead
        // of pushing the standalone /child/:id/social route.
        Card(
          child: ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('Social monitoring'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => DefaultTabController.of(context).animateTo(2),
          ),
        ),
        const SizedBox(height: 8),
        // NOTE: Wrap instead of Row — the header overflowed on 320px-wide screens.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Devices', style: Theme.of(context).textTheme.titleMedium),
            TextButton.icon(
              onPressed: () => _pairDevice(context, ref, childId),
              icon: const Icon(Icons.phonelink_setup, size: 18),
              label: const Text('Pair a device'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (devices.isEmpty)
          const Card(child: ListTile(leading: Icon(Icons.devices_other), title: Text('No devices registered')))
        else
          for (final d in devices)
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(switch (d.platform) {
                      'android' => Icons.android,
                      'ios' => Icons.apple,
                      _ => Icons.devices_other,
                    }),
                    title: Text(d.model),
                    subtitle: Text('${d.platform} ${d.osVersion} · ${_statusLabel(d)}'),
                    trailing: d.batteryPct > 0
                        ? Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: Icon(d.batteryPct <= 20 ? Icons.battery_alert : Icons.battery_std, size: 14),
                            label: Text('${d.batteryPct}%'),
                          )
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Last seen: ${formatLastSeen(d.lastSeen)}', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
                  // Plan 3.6: the latest command's real state, straight from the
                  // durable queue. An unacked command is never described as sent.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _DeviceDeliverySummary(deviceId: d.id),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    // NOTE: Wrap instead of Row — the command buttons
                    // overflowed on 320px-wide screens.
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () => context.push('/child/$childId/commands'),
                          icon: const Icon(Icons.receipt_long, size: 18),
                          label: const Text('Delivery status'),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'ring'),
                          icon: const Icon(Icons.notifications_active, size: 18),
                          label: const Text('Ring'),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'lock'),
                          icon: const Icon(Icons.lock, size: 18),
                          label: const Text('Lock'),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'unlock'),
                          icon: const Icon(Icons.lock_open, size: 18),
                          label: const Text('Unlock'),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'pause'),
                          icon: const Icon(Icons.pause_circle, size: 18),
                          label: const Text('Pause'),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'resume'),
                          icon: const Icon(Icons.play_circle, size: 18),
                          label: const Text('Resume'),
                        ),
                        TextButton.icon(
                          onPressed: () => _toggleInternet(context, ref, childId, internetPaused, d),
                          icon: Icon(internetPaused ? Icons.wifi : Icons.wifi_off, size: 18),
                          label: Text(internetPaused ? 'Resume net' : 'Pause net'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 8),
        _BonusTimeCard(childId: childId),
        const SizedBox(height: 8),
        _WindDownCard(childId: childId),
      ],
    );
  }

  /// Online when the device checked in within the last 3 minutes.
  static String _statusLabel(Device d) {
    final last = d.lastSeen;
    final online = last != null && DateTime.now().difference(last) < const Duration(minutes: 3);
    return online ? 'online' : 'offline';
  }
}

/// Compact latest-command line on a device card. It reports the durable
/// queue's state; a pending or delivered-but-unacked command is never called
/// "sent".
class _DeviceDeliverySummary extends ConsumerWidget {
  final String deviceId;
  const _DeviceDeliverySummary({required this.deviceId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(deviceCommandHistoryProvider(deviceId));
    final style = Theme.of(context).textTheme.bodySmall;
    return history.when(
      loading: () => Text('Checking command delivery…', style: style),
      error: (e, _) => Text('Command delivery unavailable', style: style),
      data: (commands) {
        if (commands.isEmpty) return Text('No commands yet', style: style);
        final latest = commands.first;
        return Text(
          'Latest: ${commandTypeLabel(latest.type)} · ${commandStatusLabel(latest.status)} · '
          '${formatCommandTime(latest.createdAt)}',
          style: style,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// Feature #10: grants one-off bonus minutes for today via
/// `POST /v1/controls/children/:id/bonus`; buttons disable while a grant
/// is in flight and the snackbar confirms the amount granted.
class _BonusTimeCard extends ConsumerStatefulWidget {
  final String childId;
  const _BonusTimeCard({required this.childId});

  @override
  ConsumerState<_BonusTimeCard> createState() => _BonusTimeCardState();
}

class _BonusTimeCardState extends ConsumerState<_BonusTimeCard> {
  bool _granting = false;

  Future<void> _grant(int minutes) async {
    setState(() => _granting = true);
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/${widget.childId}/bonus',
        data: {'minutes': minutes},
      );
      ref.invalidate(rulesProvider(widget.childId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('+$minutes extra minutes granted today')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bonus failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bonus time', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text('Extra screen time today only', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in const [15, 30, 60])
                  OutlinedButton(
                    onPressed: _granting ? null : () => _grant(minutes),
                    child: Text('+$minutes'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Feature #22: bedtime-style wind down. The OutlinedButton opens a 15/30 min
/// choice dialog; the chosen value POSTs `wind_down` for the child's devices
/// and a snackbar confirms the lock countdown.
class _WindDownCard extends ConsumerWidget {
  final String childId;
  const _WindDownCard({required this.childId});

  Future<void> _pickAndSend(BuildContext context, WidgetRef ref) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wind down'),
        content: const Text('The device shows a soft bedtime warning, then locks.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          for (final m in const [15, 30])
            FilledButton.tonal(onPressed: () => Navigator.of(ctx).pop(m), child: Text('$m min')),
        ],
      ),
    );
    if (minutes == null || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/$childId/wind-down',
        data: {'minutes': minutes},
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Screen will lock in $minutes minutes on the device')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Wind down failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Wind down', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text('Soft warning, then the screen locks', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _pickAndSend(context, ref),
              icon: const Icon(Icons.bedtime_outlined),
              label: const Text('Wind down'),
            ),
          ],
        ),
      ),
    );
  }
}

/// POSTs a lock/unlock/ring command for [device] and refreshes its delivery
/// card. The snackbar says "queued", never "sent": the POST only creates a
/// pending row (`POST /v1/devices/:id/command` → `{status: "pending"}`).
Future<void> _sendCommand(BuildContext context, WidgetRef ref, Device device, String command) async {
  try {
    await ref.read(apiClientProvider).raw.post('/v1/devices/${device.id}/command', data: {'command': command});
    ref.invalidate(deviceCommandHistoryProvider(device.id));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${command[0].toUpperCase()}${command.substring(1)} queued for ${device.model} — the device has not confirmed it yet.')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Command failed: $e')));
    }
  }
}

/// Pauses/resumes the internet for [childId]'s devices (Feature #11); the
/// status flips optimistically and reverts when the POST fails. The snackbar
/// reports a queued command, not a delivered one.
Future<void> _toggleInternet(BuildContext context, WidgetRef ref, String childId, bool paused, Device device) async {
  try {
    if (paused) {
      await resumeInternet(ref, childId);
    } else {
      await pauseInternet(ref, childId);
    }
    ref.invalidate(deviceCommandHistoryProvider(device.id));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${paused ? 'Resume' : 'Pause'} queued for ${device.model} — the device has not confirmed it yet.')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Command failed: $e')));
    }
  }
}

class _AppsTab extends ConsumerWidget {
  final String childId;
  const _AppsTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(rulesProvider(childId));
    return rules.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load rules: $e')),
      data: (ruleSet) {
        if (ruleSet.appRules.isEmpty) return const Center(child: Text('No per-app rules'));
        return ListView(
          children: [
            for (final r in ruleSet.appRules)
              ListTile(
                leading: Icon(switch (r.action) {
                  'block' => Icons.block,
                  'time_limit' => Icons.timer_outlined,
                  _ => Icons.check_circle_outline,
                }),
                title: Text(r.appName),
                subtitle: Text(r.packageId),
                trailing: Text(r.action == 'time_limit' ? '${r.dailyLimitMinutes ?? '—'} min' : r.action),
                // Feature #12: tap a row for the curated insight sheet.
                onTap: () => showAppInsightSheet(context, r.packageId),
              ),
          ],
        );
      },
    );
  }
}

class _SocialTab extends ConsumerWidget {
  final String childId;
  const _SocialTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SocialSectionsView(childId: childId);
}

class _LocationTab extends ConsumerWidget {
  final String childId;
  const _LocationTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ping = ref.watch(locationProvider(childId));
    return ping.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load location: $e')),
      data: (p) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (p == null)
            const Text('No location reported yet')
          else ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.location_on),
                title: Text('${p.lat.toStringAsFixed(6)}, ${p.lng.toStringAsFixed(6)}'),
                subtitle: Text('Accuracy ±${p.accuracyM.round()} m · '
                    '${p.timestamp == null ? 'unknown time' : DateFormat.yMMMd().add_Hms().format(p.timestamp!.toLocal())}'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Feature #15: today's location history with a time scrubber.
          _HistoryScrubber(childId: childId),
          const SizedBox(height: 12),
          // NOTE: map placeholder — a full per-child map lives on /map.
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Card(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [Icon(Icons.map_outlined, size: 48), SizedBox(height: 8), Text('Map preview')],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Feature #15: slider + ◀/▶ steppers scrubbing through today's location
/// history. The steppers jump 15 minutes along the timeline, selecting the
/// nearest ping to the target time.
class _HistoryScrubber extends ConsumerStatefulWidget {
  final String childId;
  const _HistoryScrubber({required this.childId});

  @override
  ConsumerState<_HistoryScrubber> createState() => _HistoryScrubberState();
}

class _HistoryScrubberState extends ConsumerState<_HistoryScrubber> {
  int _index = 0;

  static int _nearestIndex(List<LocationPing> pings, DateTime target) {
    var best = 0;
    var bestDiff = const Duration(days: 365);
    for (var i = 0; i < pings.length; i++) {
      final ts = pings[i].timestamp;
      if (ts == null) continue;
      final diff = ts.difference(target).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  void _step(List<LocationPing> pings, int direction) {
    final current = pings[_index.clamp(0, pings.length - 1)].timestamp;
    if (current == null) return;
    setState(() => _index = _nearestIndex(pings, current.add(Duration(minutes: 15 * direction))));
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(locationHistoryProvider(widget.childId));
    return history.when(
      loading: () => const Card(child: Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))),
      error: (e, _) => Card(child: ListTile(leading: const Icon(Icons.history), title: Text('Failed to load history: $e'))),
      data: (pings) {
        if (pings.isEmpty) {
          return const Card(child: ListTile(leading: Icon(Icons.history), title: Text('No location history for today')));
        }
        final ping = pings[_index.clamp(0, pings.length - 1)];
        final ts = ping.timestamp;
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Today's route", style: Theme.of(context).textTheme.titleMedium),
                Slider(
                  value: _index.clamp(0, pings.length - 1).toDouble(),
                  min: 0,
                  max: (pings.length - 1).toDouble(),
                  divisions: pings.length > 1 ? pings.length - 1 : null,
                  onChanged: (v) => setState(() => _index = v.round()),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Back 15 min',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _step(pings, -1),
                    ),
                    IconButton(
                      tooltip: 'Forward 15 min',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _step(pings, 1),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        ts == null
                            ? '${ping.lat.toStringAsFixed(5)}, ${ping.lng.toStringAsFixed(5)} · accuracy unknown'
                            : '${DateFormat.Hm().format(ts.toLocal())} · '
                                '${ping.lat.toStringAsFixed(5)}, ${ping.lng.toStringAsFixed(5)} · '
                                '±${ping.accuracyM.round()} m',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AlertsTab extends ConsumerWidget {  final String childId;
  const _AlertsTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider(AlertFilter(childId: childId)));
    return alerts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load alerts: $e')),
      data: (page) {
        if (page.items.isEmpty) return const Center(child: Text('No recent alerts'));
        return ListView(
          children: [
            for (final a in page.items.take(10))
              AlertTile(alert: a, onAck: () async {
                try {
                  await ref.read(apiClientProvider).raw.post('/v1/alerts/${a.id}/ack');
                } catch (_) {}
                ref.invalidate(alertsProvider);
              }),
          ],
        );
      },
    );
  }
}

/// Opens the Feature #12 insight bottom sheet for [packageId]: age rating,
/// risk chips and kid-friendly alternatives. Unknown apps (404 from the
/// curated DB) get a 'No insights' placeholder.
Future<void> showAppInsightSheet(BuildContext context, String packageId) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => _AppInsightSheet(packageId: packageId),
  );
}

class _AppInsightSheet extends ConsumerWidget {
  final String packageId;
  const _AppInsightSheet({required this.packageId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insight = ref.watch(appInsightsProvider(packageId));
    return insight.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Failed to load insights: $e'),
      ),
      data: (data) {
        if (data == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No insights for this app yet'),
          );
        }
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            Text(data.appName.isEmpty ? packageId : data.appName, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Age rating: ${data.ageRating.isEmpty ? '—' : data.ageRating}'),
            if (data.risks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Risks', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [for (final r in data.risks) Chip(visualDensity: VisualDensity.compact, label: Text(r))],
              ),
            ],
            if (data.alternatives.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Safer alternatives', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final a in data.alternatives)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [const Icon(Icons.swap_horiz, size: 16), const SizedBox(width: 8), Expanded(child: Text(a))]),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Shared alert list tile with severity coloring.
class AlertTile extends StatelessWidget {
  final Alert alert;
  final VoidCallback? onTap;
  final VoidCallback? onAck;
  const AlertTile({super.key, required this.alert, this.onTap, this.onAck});

  static Color severityColor(String severity) => switch (severity) {
        'warning' => Colors.amber,
        'critical' => Colors.red,
        _ => Colors.blue,
      };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.circle, color: severityColor(alert.severity), size: 14),
        title: Text(alert.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${alert.category} · ${alert.createdAt == null ? '' : DateFormat.MMMd().add_Hm().format(alert.createdAt!.toLocal())}'),
        trailing: onAck == null ? null : IconButton(icon: const Icon(Icons.check), tooltip: 'Acknowledge', onPressed: onAck),
        onTap: onTap,
      ),
    );
  }
}

/// Opens the pairing dialog for [childId]; refreshes the family on close so a
/// newly claimed device shows up in the Overview tab.
Future<void> _pairDevice(BuildContext context, WidgetRef ref, String childId) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _PairDeviceDialog(childId: childId),
  );
  ref.invalidate(familyProvider);
}

/// Pairing dialog: POSTs /v1/devices/pair on open, shows the 6-digit code
/// with a countdown to the server-supplied expiresAt, and auto-closes when
/// the code expires (a "New code" button re-POSTs on demand).
class _PairDeviceDialog extends ConsumerStatefulWidget {
  final String childId;
  const _PairDeviceDialog({required this.childId});

  @override
  ConsumerState<_PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends ConsumerState<_PairDeviceDialog> {
  String? _code;
  DateTime? _expiresAt;
  String? _error;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post('/v1/devices/pair', data: {'childId': widget.childId});
      final data = Map<String, dynamic>.from(res.data as Map);
      final code = data['code'] as String?;
      final expiresAt = DateTime.tryParse(data['expiresAt'] as String? ?? '');
      if (!mounted) return;
      if (code == null || expiresAt == null) {
        throw const FormatException('pair response missing code/expiresAt');
      }
      setState(() {
        _code = code;
        _expiresAt = expiresAt;
        _loading = false;
      });
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is DioException ? 'Request failed (${e.response?.statusCode ?? 'network'})' : e.toString();
      });
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final expiresAt = _expiresAt;
      if (expiresAt == null || !mounted) return;
      if (!DateTime.now().isBefore(expiresAt)) {
        _timer?.cancel();
        // auto-close on expiry; _pairDevice invalidates familyProvider
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          Navigator.of(context).pop();
        }
      } else {
        setState(() {});
      }
    });
  }

  /// Time left until the server-side expiry, clamped at zero.
  Duration get _remaining {
    final expiresAt = _expiresAt;
    if (expiresAt == null) return Duration.zero;
    final diff = expiresAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  Future<void> _copyCode() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining;
    final mm = remaining.inMinutes.toString().padLeft(2, '0');
    final ss = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pair a device', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Enter this code on the child device', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 24),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null) ...[
                Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
                FilledButton.tonal(onPressed: _generate, child: const Text('Try again')),
              ] else ...[
                Text(
                  _code!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 56, fontWeight: FontWeight.bold, letterSpacing: 12),
                ),
                const SizedBox(height: 8),
                Text('Expires in $mm:$ss', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                // NOTE: Wrap instead of Row — the two buttons overflowed the
                // 312px-wide dialog content by 36px at small widths.
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  children: [
                    TextButton.icon(onPressed: _copyCode, icon: const Icon(Icons.copy), label: const Text('Copy code')),
                    TextButton.icon(onPressed: _generate, icon: const Icon(Icons.refresh), label: const Text('New code')),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
            ],
          ),
        ),
      ),
    );
  }
}
