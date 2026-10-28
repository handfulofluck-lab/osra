import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import 'command_messages.dart';
import '../../providers/auth_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../dashboard/dashboard_screen.dart' show formatLastSeen, isDeviceOnline;
import '../pairing/pair_qr_screen.dart';
import '../social/social_screen.dart' show SocialSectionsView;
import 'command_history_screen.dart' show formatCommandTime;
import '../../api/permission_errors.dart';

/// Per-child detail view with Overview / Apps / Social / Location / Alerts tabs.
class ChildDetailScreen extends ConsumerWidget {
  final String childId;
  const ChildDetailScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == childId).firstOrNull;
    final l10n = context.l10n;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(child?.displayName ?? l10n.childFallback),
          // NOTE: scrollable — five labels no longer fit at 320px width.
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: l10n.tabOverview),
              Tab(text: l10n.tabApps),
              Tab(text: l10n.tabSocial),
              Tab(text: l10n.tabLocation),
              Tab(text: l10n.tabAlerts),
            ],
          ),
          actions: [
            IconButton(
              tooltip: l10n.reportsTooltip,
              icon: const Icon(Icons.insights),
              onPressed: () => context.push('/child/$childId/reports'),
            ),
            IconButton(
              key: const ValueKey('searchSafetyButton'),
              tooltip: l10n.searchSafetyTooltip,
              icon: const Icon(Icons.saved_search_outlined),
              onPressed: () => context.push('/child/$childId/searches'),
            ),
            // NOTE: the label clips at the left edge under about 360px (review
            // render 03, 320px Arabic), so the narrow bar keeps the same action
            // as a tooltipped icon -- the shape the other two actions use.
            // The key stays on both so a test reaches the action at any width.
            if (MediaQuery.sizeOf(context).width < 360)
              IconButton(
                key: const ValueKey('editRulesButton'),
                tooltip: l10n.editRules,
                icon: const Icon(Icons.rule),
                onPressed: () => context.push('/child/$childId/rules'),
              )
            else
              TextButton.icon(
                key: const ValueKey('editRulesButton'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => context.push('/child/$childId/rules'),
                icon: const Icon(Icons.rule, size: 18),
                label: Text(l10n.editRules),
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
    final l10n = context.l10n;
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == childId).firstOrNull;
    final devices = overview?.devicesFor(childId) ?? const <Device>[];
    final internetPaused = ref.watch(internetPausedProvider(childId)).valueOrNull ?? false;
    if (overview == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (child != null)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(child.initials)),
              title: Text(child.displayName),
              subtitle: Text(l10n.bornYear(child.birthYear)),
            ),
          ),
        // NOTE: simplest entry — the chevron jumps to the Social tab instead
        // of pushing the standalone /child/:id/social route.
        Card(
          child: ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: Text(l10n.socialMonitoringTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => DefaultTabController.of(context).animateTo(2),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        // NOTE: Wrap instead of Row — the header overflowed on 320px-wide screens.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(l10n.devices, style: Theme.of(context).textTheme.titleMedium),
            TextButton.icon(
              onPressed: () => _pairDevice(context, ref, childId),
              icon: const Icon(Icons.phonelink_setup, size: 18),
              label: Text(l10n.pairADevice),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        if (devices.isEmpty)
          Card(child: ListTile(leading: const Icon(Icons.devices_other), title: Text(l10n.noDevicesRegistered)))
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
                    subtitle: Text('${d.platform} ${d.osVersion} · ${_statusLabel(context, d)}'),
                    trailing: d.batteryPct > 0
                        ? Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: Icon(d.batteryPct <= 20 ? Icons.battery_alert : Icons.battery_std, size: 14),
                            label: Text('${d.batteryPct}%'),
                          )
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xs),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(l10n.lastSeenLabel(formatLastSeen(context, d.lastSeen)), style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
                  // Plan 3.6: the latest command's real state, straight from the
                  // durable queue. An unacked command is never described as sent.
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xxs),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: _DeviceDeliverySummary(deviceId: d.id, deviceModel: d.model),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.sm, 0, AppSpace.sm, 6),
                    // NOTE: Wrap instead of Row — the command buttons
                    // overflowed on 320px-wide screens.
                    child: Wrap(
                      spacing: AppSpace.sm,
                      children: [
                        TextButton.icon(
                          onPressed: () => context.push('/child/$childId/commands'),
                          icon: const Icon(Icons.receipt_long, size: 18),
                          label: Text(l10n.deliveryStatus),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'ring'),
                          icon: const Icon(Icons.notifications_active, size: 18),
                          label: Text(l10n.ring),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'lock'),
                          icon: const Icon(Icons.lock, size: 18),
                          label: Text(l10n.lock),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'unlock'),
                          icon: const Icon(Icons.lock_open, size: 18),
                          label: Text(l10n.unlock),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'pause'),
                          icon: const Icon(Icons.pause_circle, size: 18),
                          label: Text(l10n.pause),
                        ),
                        TextButton.icon(
                          onPressed: () => _sendCommand(context, ref, d, 'resume'),
                          icon: const Icon(Icons.play_circle, size: 18),
                          label: Text(l10n.resume),
                        ),
                        TextButton.icon(
                          onPressed: () => _toggleInternet(context, ref, childId, internetPaused, d),
                          icon: Icon(internetPaused ? Icons.wifi : Icons.wifi_off, size: 18),
                          label: Text(internetPaused ? l10n.resumeNet : l10n.pauseNet),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: AppSpace.sm),
        _BonusTimeCard(childId: childId),
        const SizedBox(height: AppSpace.sm),
        _WindDownCard(childId: childId),
        const SizedBox(height: AppSpace.sm),
        // Plan 3.7: the consent record and the withdrawal flow. Kept at the
        // end so the cards above keep their existing position at 320 px.
        Card(
          child: ListTile(
            key: const ValueKey('consentScreenTile'),
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(l10n.parentalConsent),
            subtitle: Text(l10n.consentRecordSummary),
            trailing: const Icon(Icons.arrow_forward, size: 18),
            onTap: () => context.push('/child/$childId/consent'),
          ),
        ),
      ],
    );
  }

  /// Online when the device checked in within [kDeviceOnlineWindow].
  static String _statusLabel(BuildContext context, Device d) =>
      isDeviceOnline(d.lastSeen) ? context.l10n.statusOnline : context.l10n.statusOffline;
}

/// Compact latest-command line on a device card. It reports the durable
/// queue's state; a pending or delivered-but-unacked command is never called
/// "sent".
class _DeviceDeliverySummary extends ConsumerWidget {
  final String deviceId;
  final String deviceModel;
  const _DeviceDeliverySummary({required this.deviceId, required this.deviceModel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(deviceCommandHistoryProvider(deviceId));
    final style = Theme.of(context).textTheme.bodySmall;
    final l10n = context.l10n;
    return history.when(
      loading: () => Text(l10n.checkingCommandDelivery, style: style),
      error: (e, _) => Text(l10n.commandDeliveryUnavailable, style: style),
      data: (commands) {
        if (commands.isEmpty) return Text(l10n.noCommandsYet, style: style);
        final latest = commands.first;
        final reason = latest.refusalReason;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.latestCommand(
                l10n.commandType(latest.type),
                l10n.commandStatus(latest.status),
                formatCommandTime(context, latest.createdAt),
              ),
              style: style,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            // Issue #231: a device-side refusal arrives as an ack, so this card is often the only
            // place the parent ever sees why the command did not take effect.
            if (reason != null)
              Text(
                commandRefusalText(l10n, latest.type, deviceModel, reason),
                style: style?.copyWith(color: Theme.of(context).colorScheme.error),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
          ],
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
    final l10n = context.l10n;
    setState(() => _granting = true);
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/${widget.childId}/bonus',
        data: {'minutes': minutes},
      );
      ref.invalidate(rulesProvider(widget.childId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.bonusGranted(minutes))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.bonusFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.bonusTime, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.xxs),
            Text(l10n.extraScreenTimeToday, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
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
    final l10n = context.l10n;
    final minutes = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.windDown),
        content: Text(l10n.windDownBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.cancel)),
          for (final m in const [15, 30])
            FilledButton.tonal(onPressed: () => Navigator.of(ctx).pop(m), child: Text(l10n.minutesShort(m))),
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
          SnackBar(content: Text(l10n.windDownConfirm(minutes))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.windDownFailed('$e'))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.windDown, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.xxs),
            Text(l10n.windDownSubtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpace.sm),
            OutlinedButton.icon(
              onPressed: () => _pickAndSend(context, ref),
              icon: const Icon(Icons.bedtime_outlined),
              label: Text(l10n.windDown),
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
///
/// Issue #221: the API now answers some commands with `{status: "failed",
/// reason}` instead of queueing them — a `locate_now` the phone's last
/// telemetry says it cannot answer. Reporting "queued" there would be the same
/// silent failure the refusal exists to remove, so the reason is shown instead.
Future<void> _sendCommand(BuildContext context, WidgetRef ref, Device device, String command) async {
  final l10n = context.l10n;
  try {
    final response = await ref.read(apiClientProvider).raw.post('/v1/devices/${device.id}/command', data: {'command': command});
    ref.invalidate(deviceCommandHistoryProvider(device.id));
    if (!context.mounted) return;
    final body = response.data;
    if (body is Map && body['status'] == 'failed') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_refusalMessage(l10n, command, device, body['reason']))),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.commandQueued(l10n.commandType(command), device.model))),
    );
  } on DioException catch (e) {
    if (context.mounted) {
      final body = e.response?.data;
      final code = body is Map ? (body['error'] ?? e.message) : (e.message ?? '');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(commandErrorText(l10n, command, device.model, code))));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.commandFailed('$e'))));
    }
  }
}

/// Issue #231: both the immediate POST refusal and a later device-side refusal read the same
/// mapping, so the parent is never told two different things about one command.
String _refusalMessage(AppLocalizations l10n, String command, Device device, Object? reason) =>
    commandRefusalText(l10n, command, device.model, reason);

/// Pauses/resumes the internet for [childId]'s devices (Feature #11); the
/// status flips optimistically and reverts when the POST fails. The snackbar
/// reports a queued command, not a delivered one.
Future<void> _toggleInternet(BuildContext context, WidgetRef ref, String childId, bool paused, Device device) async {
  final l10n = context.l10n;
  try {
    if (paused) {
      await resumeInternet(ref, childId);
    } else {
      await pauseInternet(ref, childId);
    }
    ref.invalidate(deviceCommandHistoryProvider(device.id));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.netQueued(paused ? l10n.resume : l10n.pause, device.model))),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.commandFailed('$e'))));
    }
  }
}

class _AppsTab extends ConsumerWidget {
  final String childId;
  const _AppsTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(childId));
    return rules.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(l10n.rulesLoadFailed('$e'))),
      data: (ruleSet) {
        if (ruleSet.appRules.isEmpty) return Center(child: Text(l10n.noPerAppRules));
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
                trailing: Text(r.action == 'time_limit'
                    ? (r.dailyLimitMinutes == null ? '—' : l10n.minutesShort(r.dailyLimitMinutes!))
                    : switch (r.action) {
                        'block' => l10n.appActionBlock,
                        'allow' => l10n.appActionAllow,
                        _ => r.action,
                      }),
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
    final l10n = context.l10n;
    final ping = ref.watch(locationProvider(childId));
    return ping.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(l10n.locationLoadFailed('$e'))),
      data: (p) => ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          if (p == null)
            Text(l10n.noLocationReported)
          else ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.location_on),
                title: Text('${p.lat.toStringAsFixed(6)}, ${p.lng.toStringAsFixed(6)}'),
                subtitle: Text(l10n.accuracyLabel(
                  p.accuracyM.round(),
                  p.timestamp == null
                      ? l10n.timeUnknown
                      : DateFormat.yMMMd(context.localeName).add_Hms().format(p.timestamp!.toLocal()),
                )),
              ),
            ),
            const SizedBox(height: AppSpace.md),
          ],
          // Feature #15: today's location history with a time scrubber.
          _HistoryScrubber(childId: childId),
          const SizedBox(height: AppSpace.md),
          // NOTE: map placeholder — a full per-child map lives on /map.
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Card(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.map_outlined, size: 48),
                  const SizedBox(height: AppSpace.sm),
                  Text(l10n.mapPreview),
                ],
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
    final l10n = context.l10n;
    final history = ref.watch(locationHistoryProvider(widget.childId));
    return history.when(
      loading: () => const Card(child: Padding(padding: EdgeInsets.all(AppSpace.lg), child: Center(child: CircularProgressIndicator()))),
      error: (e, _) => Card(
          child: ListTile(
        leading: const Icon(Icons.history),
        title: Text(readErrorText(l10n, e, () => l10n.locationHistoryLoadFailed('$e'))),
      )),
      data: (pings) {
        if (pings.isEmpty) {
          return Card(child: ListTile(leading: const Icon(Icons.history), title: Text(l10n.noLocationHistoryToday)));
        }
        final ping = pings[_index.clamp(0, pings.length - 1)];
        final ts = ping.timestamp;
        return Card(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.todaysRoute, style: Theme.of(context).textTheme.titleMedium),
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
                      tooltip: l10n.back15Tooltip,
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _step(pings, -1),
                    ),
                    IconButton(
                      tooltip: l10n.forward15Tooltip,
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _step(pings, 1),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        ts == null
                            ? '${ping.lat.toStringAsFixed(5)}, ${ping.lng.toStringAsFixed(5)} · ${l10n.accuracyUnknown}'
                            : '${DateFormat.Hm(context.localeName).format(ts.toLocal())} · '
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

class _AlertsTab extends ConsumerWidget {
  final String childId;
  const _AlertsTab({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final alerts = ref.watch(alertsProvider(AlertFilter(childId: childId)));
    return alerts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(l10n.alertsLoadFailed('$e'))),
      data: (page) {
        if (page.items.isEmpty) return Center(child: Text(l10n.noRecentAlerts));
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
    final l10n = context.l10n;
    final insight = ref.watch(appInsightsProvider(packageId));
    return insight.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpace.xxl),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Text(l10n.insightsLoadFailed('$e')),
      ),
      data: (data) {
        if (data == null) {
          return Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Text(l10n.noInsightsYet),
          );
        }
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
          children: [
            Text(data.appName.isEmpty ? packageId : data.appName, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpace.xs),
            Text(l10n.ageRating(data.ageRating.isEmpty ? '—' : data.ageRating)),
            if (data.risks.isNotEmpty) ...[
              const SizedBox(height: AppSpace.md),
              Text(l10n.risks, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpace.xs),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [for (final r in data.risks) Chip(visualDensity: VisualDensity.compact, label: Text(r))],
              ),
            ],
            if (data.alternatives.isNotEmpty) ...[
              const SizedBox(height: AppSpace.md),
              Text(l10n.saferAlternatives, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpace.xs),
              for (final a in data.alternatives)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
                  child: Row(children: [const Icon(Icons.swap_horiz, size: 16), const SizedBox(width: AppSpace.sm), Expanded(child: Text(a))]),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Shared alert list tile with severity coloring. Severity is its own semantic
/// role ([AppTokens.severityCritical] and friends) because the alert-dot
/// palette is pinned by the alert-screen test and is not the body-text
/// danger/warn/ok palette.
class AlertTile extends StatelessWidget {
  final Alert alert;
  final VoidCallback? onTap;
  final VoidCallback? onAck;
  const AlertTile({super.key, required this.alert, this.onTap, this.onAck});

  static Color severityColor(String severity, [BuildContext? context]) =>
      (context?.tokens ?? AppTokens.light).severityDot(severity);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final when = alert.createdAt == null
        ? ''
        : DateFormat.MMMd(context.localeName).add_Hm().format(alert.createdAt!.toLocal());
    return Card(
      child: ListTile(
        leading: Icon(Icons.circle, color: severityColor(alert.severity, context), size: 14),
        title: Text(l10n.alertTitleFor(alert.category, alert.title, isEnglish: context.localeName.startsWith('en')), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${l10n.alertCategory(alert.category)} · $when'),
        trailing: onAck == null ? null : IconButton(icon: const Icon(Icons.check), tooltip: l10n.acknowledgeTooltip, onPressed: onAck),
        onTap: onTap,
      ),
    );
  }
}

/// Opens the pairing screen for [childId]; refreshes the family on return so a
/// newly claimed device shows up in the Overview tab.
Future<void> _pairDevice(BuildContext context, WidgetRef ref, String childId) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => PairingQrScreen(childId: childId)),
  );
  ref.invalidate(familyProvider);
}
