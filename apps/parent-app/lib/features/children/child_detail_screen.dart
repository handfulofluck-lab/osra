import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../widgets/error_retry_view.dart';
import '../../l10n/l10n.dart';
import 'command_messages.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../rules/rules_behind_banner.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/layout_helpers.dart';
import '../dashboard/dashboard_screen.dart' show formatLastSeen;
import '../pairing/pair_qr_screen.dart';
import '../rules/active_window.dart';
import '../social/social_screen.dart' show SocialSectionsView, socialAppLabel;
import '../map/child_location_view.dart';
import 'app_groups_section.dart';
import 'child_apps_list.dart';
import 'phone_setup_section.dart';
import 'command_history_screen.dart' show formatCommandTime;
import 'device_control_state.dart';

/// Per-child detail view with Overview / Apps / Social / Location / Alerts tabs.
class ChildDetailScreen extends ConsumerWidget {
  final String childId;

  /// Which tab opens first (0 Overview … 3 Location). The dashboard's place line opens Location (Bureau #1004).
  final int initialTab;
  const ChildDetailScreen({super.key, required this.childId, this.initialTab = 0});

  /// The Location tab's index, for `/child/:id?tab=location`.
  static const int locationTab = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // #935: keep the live /v1/ws channel subscribed so `command_acked` updates delivery status immediately.
    ref.watch(wsProvider);
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == childId).firstOrNull;
    final l10n = context.l10n;
    return DefaultTabController(
      length: 5,
      initialIndex: initialTab.clamp(0, 4),
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: MediaQuery.textScalerOf(context).scale(kToolbarHeight + AppSpace.lg),
          // NOTE: ellipsis at 1.35/2.0 text scale is accepted here because the full name stands in Overview directly below.
          title: Text(
            child?.displayName ?? l10n.childFallback,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // NOTE: scrollable — five labels no longer fit at 320px width; height scales with text (B4).
          bottom: FadingScrollableTabBar(
            tabBar: TabBar(
              isScrollable: true,
              tabs: FadingScrollableTabBar.scaledTabs(context, [
                l10n.tabOverview,
                l10n.tabApps,
                l10n.tabSocial,
                l10n.tabLocation,
                l10n.tabAlerts,
              ]),
            ),
          ),
          actions: [
            // NOTE: below 360px fold the three actions into one overflow menu so scale 1.0 fits the child name without truncation.
            if (MediaQuery.sizeOf(context).width < 360)
              PopupMenuButton<String>(
                key: const ValueKey('childActionsMenu'),
                onSelected: (v) => context.push('/child/$childId/$v'),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'reports',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.insights),
                        const SizedBox(width: AppSpace.sm),
                        Flexible(child: Text(l10n.reportsTooltip)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'searches',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.saved_search_outlined),
                        const SizedBox(width: AppSpace.sm),
                        Flexible(child: Text(l10n.searchSafetyTooltip)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rules',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.rule),
                        const SizedBox(width: AppSpace.sm),
                        Flexible(child: Text(l10n.editRules)),
                      ],
                    ),
                  ),
                ],
              )
            else ...[
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
              IconButton(
                key: const ValueKey('editRulesButton'),
                tooltip: l10n.editRules,
                icon: const Icon(Icons.rule),
                constraints: const BoxConstraints(
                  minWidth: kMinInteractiveDimension,
                  minHeight: kMinInteractiveDimension,
                ),
                onPressed: () => context.push('/child/$childId/rules'),
              ),
            ],
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
    return RefreshIndicator(
      // #876: the delivery line on this tab had no way to be refreshed by hand — pulling down did nothing.
      onRefresh: () async {
        ref.invalidate(familyProvider);
        for (final device in devices) {
          ref.invalidate(deviceCommandHistoryProvider(device.id));
        }
      },
      child: SingleChildScrollView(
      // The pull gesture needs something scrollable even when the content fits: `AlwaysScrollable` keeps it
      // working on a short page and at a large text scale alike.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (child != null) ...[
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(child.initials)),
                title: Text(child.displayName),
                subtitle: Text(l10n.bornYear(child.birthYear)),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            FilledButton.tonal(
              key: const ValueKey('overviewEditRulesButton'),
              onPressed: () => context.push('/child/$childId/rules'),
              child: Text(l10n.editRules),
            ),
          ],
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
                    subtitle: Text(switch (formatDevicePlatformLabel(d.platform, d.osVersion)) {
                      '' => _statusLabel(context, d),
                      final platformLabel => '$platformLabel · ${_statusLabel(context, d)}',
                    }),
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
                  // ADR-0034 decision 3: what this phone says it can do, and what is missing.
                  PhoneSetupSection(device: d),
                  // ADR-0037 PR B3c: the iPhone's app groups, each with a Block switch.
                  AppGroupsSection(device: d),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // #969: name the scope of each group, so a parent knows which commands reach one
                        // handset and which reach the family.
                        // U59 + U60 (#650, 7119037302, 7047663129): 2-column tonal action grid with 48 dp
                        // targets and a single server-confirmed Pause/Resume device control.
                        _ScopeLabel(
                          key: const ValueKey('scopeThisDevice'),
                          label: l10n.scopeThisDevice,
                        ),
                        const SizedBox(height: AppSpace.xs),
                        _DeviceActionsSection(
                          childId: childId,
                          device: d,
                          onSend: (command) => _sendCommand(context, ref, d, command),
                          onOpenHistory: () => context.push('/child/$childId/commands'),
                        ),
                        // #969: a queued command is not a done command. This line names this handset and says
                        // which state it is in; the wording is the Arabic Language Bureau's per-device copy, not
                        // the command-history keys, which describe a delivery state rather than a device.
                        _DeviceControlLine(deviceId: d.id),
                        const SizedBox(height: AppSpace.sm),
                        _ScopeLabel(
                          key: const ValueKey('scopeAllDevices'),
                          label: l10n.scopeAllDevices,
                        ),
                        const SizedBox(height: AppSpace.xs),
                        SizedBox(
                          width: double.infinity,
                          child: _deviceTonalButton(
                            key: ValueKey('deviceAction-internet-${d.id}'),
                            onPressed: () => _toggleInternet(context, ref, childId, internetPaused, d),
                            icon: internetPaused ? Icons.wifi : Icons.wifi_off,
                            label: internetPaused ? l10n.commandResumeInternet : l10n.commandPauseInternet,
                          ),
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
      ),
    ),
    );
  }

  /// The server's judgement (`Device.status`), never a clock rule on this phone (#601).
  static String _statusLabel(BuildContext context, Device d) =>
      d.isOnline ? context.l10n.statusOnline : context.l10n.statusOffline;
}

/// U59 (#650, #50 7047663129): server-confirmed pause/resume state for a single handset.
@immutable
class DevicePauseControlState {
  /// True only when the newest acknowledged pause/resume command is `pause`.
  final bool confirmedPaused;

  /// True when the newest pause/resume command overall is `pending` or `delivered`.
  final bool waiting;

  /// The waiting command (`'pause'` or `'resume'`) when [waiting] is true.
  final String? pendingCommand;

  const DevicePauseControlState({
    required this.confirmedPaused,
    required this.waiting,
    this.pendingCommand,
  });

  /// The single action the device card exposes: `'resume'` when server-confirmed paused,
  /// otherwise `'pause'`.
  String get activeCommand => confirmedPaused ? 'resume' : 'pause';
}

/// Resolves the single server-confirmed Pause/Resume control state from [history] (U59).
///
/// Only the newest `acked` pause/resume command flips [DevicePauseControlState.confirmedPaused],
/// and only the newest pause/resume command overall decides [DevicePauseControlState.waiting]
/// (so an old unconfirmed row never blocks the button after a newer acked row, #969 F1).
DevicePauseControlState resolveDevicePauseControlState(List<DeviceCommand> history) {
  DeviceCommand? newest;
  DeviceCommand? newestAcked;
  for (final c in history) {
    if (c.type != 'pause' && c.type != 'resume') continue;
    final after = newest?.createdAt;
    if (newest == null || after == null || (c.createdAt?.isAfter(after) ?? false)) {
      newest = c;
    }
    if (c.status == 'acked') {
      final ackAfter = newestAcked?.createdAt;
      if (newestAcked == null || ackAfter == null || (c.createdAt?.isAfter(ackAfter) ?? false)) {
        newestAcked = c;
      }
    }
  }
  final confirmedPaused = newestAcked?.type == 'pause';
  final waiting = newest != null && (newest.status == 'pending' || newest.status == 'delivered');
  return DevicePauseControlState(
    confirmedPaused: confirmedPaused,
    waiting: waiting,
    pendingCommand: waiting ? newest.type : null,
  );
}

/// U60 (#650, 7119037302): shared 48 dp tonal button for device card actions.
Widget _deviceTonalButton({
  Key? key,
  required VoidCallback? onPressed,
  required IconData icon,
  required String label,
}) {
  return FilledButton.tonalIcon(
    key: key,
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.sm),
      alignment: AlignmentDirectional.centerStart,
      tapTargetSize: MaterialTapTargetSize.padded,
    ),
    icon: Icon(icon, size: 18),
    label: Text(label, softWrap: true),
  );
}

/// U60 (#650, 7119037302): 2-column action grid for per-device controls, falling back to
/// 1 column on ultra-narrow viewports (`< 268 dp`) so 200% text scale never overflows.
class _DeviceActionGrid extends StatelessWidget {
  final List<Widget> children;
  const _DeviceActionGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCols = constraints.maxWidth >= 268;
        if (!twoCols) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpace.xs),
                children[i],
              ],
            ],
          );
        }
        return Column(
          key: const ValueKey('deviceActionGrid2Col'),
          children: [
            for (var i = 0; i < children.length; i += 2) ...[
              if (i > 0) const SizedBox(height: AppSpace.xs),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: children[i]),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: i + 1 < children.length ? children[i + 1] : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// U59 + U60 + U61 (#650, #969, 7120730242): per-device action grid.
///
/// While a pause/resume command is waiting on the handset, the busy control spans the full
/// row of the grid (B6, 7120730242) so "Pausing…" / "Resuming…" / «جارٍ إيقاف الجهاز…» never
/// orphan their ellipsis on a separate line and the waiting state stands out clearly.
class _DeviceActionsSection extends ConsumerWidget {
  final String childId;
  final Device device;
  final void Function(String command) onSend;
  final VoidCallback onOpenHistory;
  const _DeviceActionsSection({
    required this.childId,
    required this.device,
    required this.onSend,
    required this.onOpenHistory,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(deviceCommandHistoryProvider(device.id)).valueOrNull ?? const <DeviceCommand>[];
    final pauseState = resolveDevicePauseControlState(history);

    final pauseWidget = _buildPauseControl(context, pauseState);
    final historyButton = _deviceTonalButton(
      key: ValueKey('deviceAction-history-${device.id}'),
      onPressed: onOpenHistory,
      icon: Icons.receipt_long,
      label: l10n.deliveryStatus,
    );

    final pairChildren = <Widget>[
      _deviceTonalButton(
        key: ValueKey('deviceAction-ring-${device.id}'),
        onPressed: () => onSend('ring'),
        icon: Icons.notifications_active,
        label: l10n.ring,
      ),
      _deviceTonalButton(
        key: ValueKey('deviceAction-stopRing-${device.id}'),
        onPressed: () => onSend('stop_ring'),
        icon: Icons.notifications_off_outlined,
        label: l10n.commandStopRing,
      ),
      _deviceTonalButton(
        key: ValueKey('deviceAction-lock-${device.id}'),
        onPressed: () => onSend('lock'),
        icon: Icons.lock,
        label: l10n.lock,
      ),
      _deviceTonalButton(
        key: ValueKey('deviceAction-unlock-${device.id}'),
        onPressed: () => onSend('unlock'),
        icon: Icons.lock_open,
        label: l10n.unlock,
      ),
      if (!pauseState.waiting) ...[
        pauseWidget,
        historyButton,
      ],
    ];

    if (!pauseState.waiting) {
      return _DeviceActionGrid(children: pairChildren);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DeviceActionGrid(children: pairChildren),
        const SizedBox(height: AppSpace.xs),
        SizedBox(
          key: ValueKey('deviceAction-pauseFullRow-${device.id}'),
          width: double.infinity,
          child: pauseWidget,
        ),
        const SizedBox(height: AppSpace.xs),
        SizedBox(width: double.infinity, child: historyButton),
      ],
    );
  }

  Widget _buildPauseControl(BuildContext context, DevicePauseControlState state) {
    final l10n = context.l10n;
    final command = state.activeCommand;
    final label = state.waiting
        ? (state.pendingCommand == 'resume' ? l10n.commandResumingDevice : l10n.commandPausingDevice)
        : (state.confirmedPaused ? l10n.commandResumeDevice : l10n.commandPauseDevice);
    final button = _deviceTonalButton(
      key: ValueKey('deviceAction-$command-${device.id}'),
      onPressed: state.waiting ? null : () => onSend(command),
      icon: state.confirmedPaused ? Icons.play_circle : Icons.pause_circle,
      label: label,
    );
    if (!state.waiting) return button;
    return Tooltip(
      key: ValueKey('controlPending-${state.pendingCommand}'),
      message: l10n.statusPending,
      child: button,
    );
  }
}

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
      // Issue #475 follow-up: a bonus grant bumps rulesVersion (`controls.ts:88`), so the family
      // snapshot has to be refetched or the "not picked up yet" line can never appear after "+15 min".
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.bonusGranted(minutes))),
        );
      }
    } on DioException catch (e) {
      // #441 review: the bonus route runs `requireConsent` too, so a 428 needs the sentence, not '$e'.
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.bonusFailed),
          onRetry: () => _grant(minutes),
        );
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.bonusFailed),
          onRetry: () => _grant(minutes),
        );
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
            // Issue #475 follow-up: a grant bumps rulesVersion, so the card that grants it says whether
            // the phone has caught up yet. Renders nothing when it has, or when it never reported.
            RulesBehindBanner(childId: widget.childId),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                for (final minutes in const [15, 30, 60])
                  OutlinedButton(
                    onPressed: _granting ? null : () => _grant(minutes),
                    child: Text(ltrIsolate('+$minutes')),
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
        scrollable: true,
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
    } on DioException catch (e) {
      // #441 review: wind-down is a `controls.ts` write like the others.
      if (context.mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.windDownFailed),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.windDownFailed),
        );
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
    // F1 (review 7039886009): no re-read here. A POST that queues the command answers `{status: "pending"}`
    // before the phone has even received it, so asking for `/latest` at that moment returns the same 404 or
    // the same older fix — a wasted request dressed up as a refresh. The fresh fix arrives when the phone
    // publishes its ping: the `location` message on `/v1/ws` calls `invalidateLocation` (`family_provider.dart`
    // `applyRealtimeMessage`), which is what a parent sees the tab update on.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.commandQueued(l10n.commandType(command), device.model))),
    );
  } on DioException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(commandErrorText(l10n, command, device.model, e))));
    }
  } catch (e) {
    if (context.mounted) {
      showErrorSnackBar(
        context,
        friendlyErrorText(l10n, e, () => l10n.commandFailed),
      );
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
  } on ControlsRefusal catch (r) {
    // Issue #437 A2: a refused pause/resume says why, through the same mapping every write uses.
    if (context.mounted) {
      showErrorSnackBar(
        context,
        friendlyErrorText(l10n, r.error, () => l10n.commandFailed),
      );
    }
  } catch (e) {
    if (context.mounted) {
      showErrorSnackBar(
        context,
        friendlyErrorText(l10n, e, () => l10n.commandFailed),
      );
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
    final overview = ref.watch(familyProvider).valueOrNull;
    final devices = overview?.devicesFor(childId) ?? const <Device>[];
    final childHasIphone = devices.any((d) => d.platform == 'ios');
    final childHasAndroid = devices.any((d) => d.platform == 'android');
    // U40 (#953): headings exist only for a child who has both phones. With one platform the tab is
    // about one list, and a heading over the only list says nothing a parent cannot see.
    final mixedFamily = childHasAndroid && childHasIphone;
    final childName = overview?.children.where((c) => c.id == childId).firstOrNull?.displayName ?? '';
    final groupDevices = [
      for (final d in devices)
        if (d.setup?.groups?.isNotEmpty ?? false) d,
    ];
    final canManagePerAppRules = childHasAndroid || !childHasIphone;
    // #456: the clock is a provider so a row can pin the sentence to a weekday morning.
    // #476: and it is read on the family's clock, where the child's phone enforces the window.
    final offset = overview?.family.utcOffsetMinutes;
    final now = familyWallClock(ref.watch(clockProvider)(), offset);
    // Karim 23 Nov: every app on the phone, with its icon and a one-tap switch, once the phone has
    // reported its apps. Until then the tab keeps the rule list it always had.
    final installed = canManagePerAppRules ? ref.watch(installedAppsProvider(childId)).valueOrNull : null;
    return rules.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetryView(
        message: friendlyErrorText(l10n, e, () => l10n.rulesLoadFailed),
        onRetry: () => ref.invalidate(rulesProvider(childId)),
      ),
      data: (ruleSet) {
        return ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
          children: [
            // F1 (UI/UX Bureau 7043461404, Arabic Bureau 7043544512): a mixed family always sees both headings, in
            // both states. Without the iPhone heading above the empty card, the card reads as being about all the
            // child's apps while an Android list with apps sits directly under it.
            if (mixedFamily)
              Padding(
                key: const ValueKey('appsTabIphoneHeading'),
                padding: const EdgeInsetsDirectional.fromSTEB(0, AppSpace.sm, 0, AppSpace.xs),
                child: Text(l10n.appsTabIphoneHeading, style: Theme.of(context).textTheme.titleMedium),
              ),
            if (groupDevices.isNotEmpty) ...[
              for (final d in groupDevices)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: AppGroupsSection(device: d),
                  ),
                ),
              const SizedBox(height: AppSpace.sm),
            ] else if (childHasIphone) ...[
              // U42 (#953): the iPhone empty state, so a parent is never told about a PIN or where a
              // group was made. The child's name is isolated because it is Latin inside an Arabic line.
              Card(
                key: const ValueKey('appsTabIphoneSetupCard'),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.appPickerIosEmptyTitle, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpace.xs),
                      Text(l10n.appPickerIosEmptyBody(ltrIsolate(childName)),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            if (mixedFamily && canManagePerAppRules)
              Padding(
                key: const ValueKey('appsTabAndroidHeading'),
                padding: const EdgeInsetsDirectional.fromSTEB(0, AppSpace.sm, 0, AppSpace.xs),
                child: Text(l10n.appsTabAndroidHeading, style: Theme.of(context).textTheme.titleMedium),
              ),
            if (canManagePerAppRules) ...[
              FilledButton.tonalIcon(
                key: const ValueKey('appsTabManageAppsButton'),
                onPressed: () => context.push('/child/$childId/rules?tab=apps'),
                icon: const Icon(Icons.block, size: 18),
                label: Text(l10n.editRules),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            if (canManagePerAppRules && installed != null && installed.apps.isNotEmpty)
              ChildAppsList(
                key: const ValueKey('childAppsList'),
                childId: childId,
                ruleSet: ruleSet,
                report: installed,
                windowNote: (packageId) => _windowNote(context, packageId, ruleSet, now),
                onInsight: (packageId) => showAppInsightSheet(context, packageId),
              )
            else if (ruleSet.appRules.isEmpty && canManagePerAppRules)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                child: Center(child: Text(l10n.noPerAppRules)),
              )
            else if (ruleSet.appRules.isNotEmpty)
              for (final r in ruleSet.appRules)
              ListTile(
                leading: Icon(switch (r.action) {
                  'block' => Icons.block,
                  'time_limit' => Icons.timer_outlined,
                  _ => Icons.check_circle_outline,
                }),
                title: Text(r.appName),
                // Karim 23 Nov: a parent reads the app's name, never its package id.
                subtitle: _windowNote(context, r.packageId, ruleSet, now),
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

/// #456: name the window that is overriding this app, so an "Allowed" row that the phone refuses
/// explains itself. Null when no bedtime, school or routine window is blocking it now.
Widget? _windowNote(BuildContext context, String packageId, RuleSet ruleSet, DateTime now) {
  final l10n = context.l10n;
  final window = activeWindowFor(packageId: packageId, rules: ruleSet, now: now);
  if (window == null) return null;
  return Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(
      l10n.blockedNowBy(
        switch (window.kind) {
          WindowKind.school => l10n.schoolHours,
          WindowKind.bedtime => l10n.bedtime,
          WindowKind.routine => window.routineName ?? l10n.tabRoutines,
        },
        window.endsAt,
      ),
      key: ValueKey('blocked-now-$packageId'),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
    ),
  );
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
    final childName = ref.watch(familyProvider).valueOrNull?.children.where((c) => c.id == childId).firstOrNull?.displayName ?? '';
    // #869: the app could *show* a `locate_now` in a device's command history but had no way to send one, so
    // "Locate the child" had nothing behind it. It sits here, next to the state a parent reads when there is no
    // position, rather than in the device-command row — that row already wraps to three lines at 320 px and one
    // more button pushed an existing control out of the tapped area.
    //
    // F2 (review 7039886009): a child can have more than one phone. One unlabelled button wired to the first
    // device would leave every other device unreachable, and the parent could not tell which phone was asked,
    // so there is one button per device and each names its phone when there is more than one.
    final devices = ref.watch(familyProvider).valueOrNull?.devicesFor(childId) ?? const <Device>[];
    final locate = devices.isEmpty
        ? null
        : Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              for (final d in devices)
                OutlinedButton.icon(
                  key: ValueKey('locateNow-${d.id}'),
                  onPressed: () => _sendCommand(context, ref, d, 'locate_now'),
                  icon: const Icon(Icons.my_location, size: 18),
                  label: Text(devices.length == 1
                      ? l10n.commandLocateNow
                      : '${l10n.commandLocateNow} (${ltrIsolate(d.model)})'),
                ),
            ],
          );
    return ping.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      // #850: never show exception text to a parent. A read refused for permission says so; anything
      // else is the plain localized line, with no error detail.
      error: (e, _) => ErrorRetryView(
        message: friendlyErrorText(l10n, e, () => l10n.locationLoadFailed),
        onRetry: () => ref.invalidate(locationProvider(childId)),
      ),
      data: (p) => ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          if (locate != null) ...[
            Align(alignment: AlignmentDirectional.centerStart, child: locate),
            const SizedBox(height: AppSpace.sm),
          ],
          if (p == null)
            Text(l10n.noLocationReported)
          else ...[
            // Karim 22 Nov: a real map, a place name and freshness, never raw coordinates.
            ChildLocationCard(ping: p, childName: childName),
            const SizedBox(height: AppSpace.md),
          ],
          // Feature #15: today's location history with a time scrubber.
          _HistoryScrubber(childId: childId),
          const SizedBox(height: AppSpace.md),
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
        title: Text(friendlyErrorText(l10n, e, () => l10n.locationHistoryLoadFailed)),
        trailing: TextButton(
          onPressed: () => ref.invalidate(locationHistoryProvider(widget.childId)),
          child: Text(l10n.retry),
        ),
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PlaceNameText(ping: ping, style: Theme.of(context).textTheme.bodyMedium, maxLines: 1),
                          Text(
                            ts == null
                                ? l10n.accuracyUnknown
                                : '${DateFormat.Hm(context.localeName).format(ts.toLocal())} · '
                                    '${l10n.accuracyShort(ping.accuracyM.round())}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
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
      error: (e, _) => ErrorRetryView(
        message: friendlyErrorText(l10n, e, () => l10n.alertsLoadFailed),
        onRetry: () => ref.invalidate(alertsProvider(AlertFilter(childId: childId))),
      ),
      data: (page) {
        if (page.items.isEmpty) return Center(child: Text(l10n.noRecentAlerts));
        return ListView(
          children: [
            for (final a in page.items.take(10))
              AlertTile(alert: a, onAck: () async {
                try {
                  await ref.read(apiClientProvider).raw.post('/v1/alerts/${a.id}/ack');
                  ref.read(alertsSeenProvider.notifier).markAcknowledged(a.id);
                  ref.invalidate(unacknowledgedAlertsProvider);
                  ref.invalidate(unacknowledgedCountProvider);
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
        child: ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.insightsLoadFailed),
          onRetry: () => ref.invalidate(appInsightsProvider(packageId)),
        ),
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
  /// #1029: count of additional flagged messages that arrived after the parent last opened this alert.
  final int newSinceCount;
  const AlertTile({
    super.key,
    required this.alert,
    this.onTap,
    this.onAck,
    this.newSinceCount = 0,
  });

  static Color severityColor(String severity, [BuildContext? context]) =>
      (context?.tokens ?? AppTokens.light).severityDot(severity);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);

    final String titleText;
    final String? socialContactLine;
    final String? socialLatestLine;
    final String? genericSubtitleText;
    if (alert.hasSocialCountSummary) {
      final appKey = alert.metadata['app']?.toString().trim().toLowerCase() ?? '';
      final appLabel = ltrIsolate(socialAppLabel(appKey, l10n));
      titleText = l10n.socialAlertCountTitle(alert.socialMessageCount, appLabel);
      final latestAt = alert.effectiveTimestamp;
      final latestClock = latestAt == null
          ? ''
          : ltrIsolate(normalizeDigits(DateFormat('HH:mm', 'en').format(latestAt.toLocal())));
      final contactName = alert.socialContactName;
      final contactDisplay = contactName != null
          ? firstStrongIsolate(contactName)
          : l10n.socialAlertUnknownContact;
      socialContactLine = l10n.socialAlertFromContactOnly(contactDisplay);
      socialLatestLine = latestClock.isEmpty ? null : l10n.socialAlertLatestAt(latestClock);
      genericSubtitleText = null;
    } else {
      final when = alert.createdAt == null
          ? ''
          : DateFormat.MMMd(context.localeName).add_Hm().format(alert.createdAt!.toLocal());
      titleText = l10n.alertTitleFor(
        alert.category,
        alert.title,
        isEnglish: context.localeName.startsWith('en'),
        tamperType: alert.metadata['type']?.toString(),
      );
      socialContactLine = null;
      socialLatestLine = null;
      // #760: a ring alert's subtitle is the Bureau's sentence for what happened to that ring (dismissed,
      // PIN-stopped, parent-stopped, timed out), never the generic category line — the category is "ring",
      // which tells a parent nothing. `alertBodyFor` falls back to the server body for any other category.
      final ringLine = alert.category == 'ring' ? alertBodyFor(alert, l10n) : '';
      genericSubtitleText = ringLine.isEmpty
          ? '${l10n.alertCategory(alert.category)} · $when'
          : (when.isEmpty ? ringLine : '$ringLine · $when');
    }

    final Widget? newBadge = newSinceCount > 0
        ? Container(
            key: ValueKey('alert-new-since-${alert.id}'),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              l10n.socialAlertNewSince(newSinceCount),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        : null;

    final mutedStyle = theme.textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant);
    final Widget subtitleContent;
    if (alert.hasSocialCountSummary) {
      subtitleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            socialContactLine!,
            key: ValueKey('alert-contact-${alert.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: mutedStyle,
          ),
          if (socialLatestLine != null)
            Text(
              socialLatestLine,
              key: ValueKey('alert-latest-${alert.id}'),
              style: mutedStyle,
            ),
          if (newBadge != null) ...[
            const SizedBox(height: AppSpace.xs),
            newBadge,
          ],
        ],
      );
    } else {
      // #760: a ring's subtitle is the Bureau's sentence plus a timestamp, so it gets two lines; every other
      // alert type keeps one. Taking main's tile dropped that rule when the branch's tile was replaced.
      final genericWidget = Text(genericSubtitleText!, maxLines: alert.category == 'ring' ? 2 : 1);
      subtitleContent = newBadge == null
          ? genericWidget
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                genericWidget,
                const SizedBox(height: AppSpace.xs),
                newBadge,
              ],
            );
    }

    return Card(
      key: ValueKey('alert-card-${alert.id}'),
      child: ListTile(
        leading: Icon(Icons.circle, color: severityColor(alert.severity, context), size: 14),
        title: Text(
          titleText,
          maxLines: alert.hasSocialCountSummary ? 3 : 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitleContent,
        trailing: onAck == null
            ? null
            : IconButton(
                icon: const Icon(Icons.check),
                tooltip: l10n.acknowledgeTooltip,
                onPressed: onAck,
              ),
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

/// A group heading on the child card: which controls address this handset, which address the family (#969).
class _ScopeLabel extends StatelessWidget {
  final String label;
  const _ScopeLabel({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.sm, AppSpace.xs, 0, 0),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

/// The per-handset status line: waiting, or refused (#969). Silent when the newest command is acked.
class _DeviceControlLine extends ConsumerWidget {
  final String deviceId;
  const _DeviceControlLine({required this.deviceId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(deviceCommandHistoryProvider(deviceId)).valueOrNull ?? const <DeviceCommand>[];
    final line = deviceControlLine(history);
    if (line == DeviceControlLine.none) return const SizedBox.shrink();
    final l10n = context.l10n;
    final failed = line == DeviceControlLine.failed;
    return Padding(
      key: ValueKey(failed ? 'deviceControlFailed' : 'deviceControlPending'),
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.sm, AppSpace.xxs, AppSpace.sm, 0),
      child: Text(
        failed ? l10n.deviceControlFailed : l10n.deviceControlPending,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: failed ? context.tokens.danger : context.tokens.warn,
        ),
      ),
    );
  }
}
