import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../dashboard/dashboard_screen.dart' show formatLastSeen;
import '../rules/rules_behind_banner.dart';
import '../rules/rules_freshness.dart';
import '../social/social_app_catalog.dart';
import 'command_history_screen.dart' show formatCommandTime;

/// Feature switch for UX Final Decisions P-08 Child Overview (#1179).
///
/// Enable at build time via `--dart-define=OSRA_UX_P08=true`, or override
/// [p08ChildOverviewEnabledProvider] in widget tests. When `false`,
/// `ChildDetailScreen` falls back to the legacy 5-tab layout.
const bool kEnableUxP08ChildOverview = bool.fromEnvironment(
  'OSRA_UX_P08',
  defaultValue: false,
);

/// Switch provider controlling whether `ChildDetailScreen` opens the P-08
/// Child Overview (#1179) or falls back to the legacy 5-tab screen.
final p08ChildOverviewEnabledProvider = Provider<bool>(
  (ref) => kEnableUxP08ChildOverview,
);

/// UX Final Decisions **P-08 Child Overview** (#1179):
/// - Time-left card on top with child identity, live status, battery, and
///   named device ("Switch device" shown ONLY when `devices.length > 1`).
/// - Proof line: `"Applied on <device> at <HH:mm>"` when rules are current and
///   acknowledged, or `"Sent to phone"` while waiting / behind.
/// - 8 read-only tiles opening each rule/detail screen (Daily limit, Bedtime,
///   Apps, Web filter, Places, Social, Devices, This week — week delta hidden
///   until #1058 ships).
/// - 4 Quick Actions below: Lock, Pause net (All paired devices), Ring / Stop
///   ringing, and +30 min, plus the latest command delivery proof line.
///
/// Strictly follows `#1179` build conditions: `AppTokens` only, dark + light,
/// 200% text scale at 320 px, `firstStrongIsolate` for names, `ltrIsolate` for
/// numbers/models/times, Western digits, 48 dp targets, no 3/5 tabs, no
/// "Protected 81%" badge, no "−12%" delta.
class ChildOverviewP08Screen extends ConsumerStatefulWidget {
  final String childId;
  const ChildOverviewP08Screen({super.key, required this.childId});

  @override
  ConsumerState<ChildOverviewP08Screen> createState() =>
      _ChildOverviewP08ScreenState();
}

class _ChildOverviewP08ScreenState
    extends ConsumerState<ChildOverviewP08Screen> {
  String? _selectedDeviceId;
  bool _grantingBonus = false;
  bool _sendingCommand = false;
  bool _ringSent = false;

  String get _childId => widget.childId;

  Device? _resolveDevice(List<Device> devices) {
    if (devices.isEmpty) return null;
    if (_selectedDeviceId != null) {
      final match = devices.where((d) => d.id == _selectedDeviceId).firstOrNull;
      if (match != null) return match;
    }
    return devices.first;
  }

  /// Formats a duration in minutes using localized words and Western digits.
  String _formatDuration(BuildContext context, int totalMinutes) {
    final l10n = context.l10n;
    final clamped = totalMinutes < 0 ? 0 : totalMinutes;
    final h = clamped ~/ 60;
    final m = clamped % 60;
    if (h > 0 && m > 0) {
      return l10n.childOverviewDurationHoursMinutes(
        l10n.childOverviewDurationHours(h),
        l10n.childOverviewDurationMinutes(m),
      );
    }
    if (h > 0) return l10n.childOverviewDurationHours(h);
    return l10n.childOverviewDurationMinutes(m);
  }

  /// Formats a local HH:mm timestamp in Western digits, isolated LTR.
  String _formatHHmm(DateTime ts) {
    final local = ts.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return ltrIsolate('$hh:$mm');
  }

  Future<void> _switchDeviceSheet(List<Device> devices, Device current) async {
    final l10n = context.l10n;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.lg,
                AppSpace.xs,
                AppSpace.lg,
                AppSpace.sm,
              ),
              child: Text(
                l10n.childOverviewSwitchDevice,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final d in devices)
              ListTile(
                key: ValueKey('p08-device-option-${d.id}'),
                leading: Icon(_platformIcon(d.platform)),
                title: Text(ltrIsolate(d.model)),
                subtitle: Text(
                  d.isOnline ? l10n.statusOnline : l10n.statusOffline,
                ),
                trailing: d.id == current.id
                    ? Icon(Icons.check, color: ctx.tokens.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(d.id),
              ),
            const SizedBox(height: AppSpace.sm),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDeviceId = picked;
        _ringSent = false;
      });
    }
  }

  Future<void> _lockAllDevices(List<Device> devices) async {
    if (_sendingCommand || devices.isEmpty) return;
    final l10n = context.l10n;
    setState(() => _sendingCommand = true);
    try {
      for (final d in devices) {
        await ref.read(apiClientProvider).raw.post(
          '/v1/devices/${d.id}/command',
          data: {'command': 'lock'},
        );
        ref.invalidate(deviceCommandHistoryProvider(d.id));
      }
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.commandQueued(
                l10n.commandLock,
                devices.length == 1
                    ? ltrIsolate(devices.first.model)
                    : l10n.scopeAllDevices,
              ),
            ),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => _unlockAllDevices(devices),
            ),
          ),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.commandFailed),
          onRetry: () => _lockAllDevices(devices),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingCommand = false);
    }
  }

  Future<void> _unlockAllDevices(List<Device> devices) async {
    for (final d in devices) {
      try {
        await ref.read(apiClientProvider).raw.post(
          '/v1/devices/${d.id}/command',
          data: {'command': 'unlock'},
        );
        ref.invalidate(deviceCommandHistoryProvider(d.id));
      } catch (_) {}
    }
    ref.invalidate(familyProvider);
  }

  Future<void> _sendWindDown() async {
    if (_sendingCommand) return;
    final l10n = context.l10n;
    setState(() => _sendingCommand = true);
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/$_childId/wind-down',
        data: {'minutes': 10},
      );
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.windDownConfirm(10))),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.windDownFailed),
          onRetry: _sendWindDown,
        );
      }
    } finally {
      if (mounted) setState(() => _sendingCommand = false);
    }
  }

  /// A1–A5 (#1179): per-device controls + wind-down + command history reachable
  /// from one calm "More actions" sheet on the named device.
  Future<void> _openMoreActionsSheet(Device device) async {
    final l10n = context.l10n;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.lg,
                AppSpace.xs,
                AppSpace.lg,
                AppSpace.sm,
              ),
              child: Text(
                ltrIsolate(device.model),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              key: const ValueKey('p08More-pauseDevice'),
              leading: const Icon(Icons.pause_circle_outline),
              title: Text(l10n.commandPauseDevice),
              onTap: () => Navigator.of(ctx).pop('pause'),
            ),
            ListTile(
              key: const ValueKey('p08More-lockDevice'),
              leading: const Icon(Icons.lock_outline),
              title: Text(l10n.commandLock),
              onTap: () => Navigator.of(ctx).pop('lock'),
            ),
            ListTile(
              key: const ValueKey('p08More-unlockDevice'),
              leading: const Icon(Icons.lock_open_outlined),
              title: Text(l10n.unlock),
              onTap: () => Navigator.of(ctx).pop('unlock'),
            ),
            ListTile(
              key: const ValueKey('p08More-ringDevice'),
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(_ringSent ? l10n.commandStopRing : l10n.commandRing),
              onTap: () => Navigator.of(ctx).pop(_ringSent ? 'stop_ring' : 'ring'),
            ),
            ListTile(
              key: const ValueKey('p08More-windDown'),
              leading: const Icon(Icons.bedtime_outlined),
              title: Text(l10n.windDown),
              onTap: () => Navigator.of(ctx).pop('wind_down'),
            ),
            ListTile(
              key: const ValueKey('p08More-commands'),
              leading: const Icon(Icons.receipt_long),
              title: Text(l10n.deliveryStatus),
              onTap: () => Navigator.of(ctx).pop('commands'),
            ),
            const SizedBox(height: AppSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'commands':
        context.push('/child/$_childId/commands');
      case 'wind_down':
        await _sendWindDown();
      default:
        await _sendDeviceCommand(device, action);
    }
  }

  Future<void> _sendDeviceCommand(Device device, String command) async {
    if (_sendingCommand) return;
    final l10n = context.l10n;
    setState(() => _sendingCommand = true);
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/devices/${device.id}/command',
        data: {'command': command},
      );
      ref.invalidate(deviceCommandHistoryProvider(device.id));
      ref.invalidate(familyProvider);
      if (mounted) {
        if (command == 'ring') {
          setState(() => _ringSent = true);
        } else if (command == 'stop_ring') {
          setState(() => _ringSent = false);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.commandQueued(
                _commandLabel(l10n, command),
                ltrIsolate(device.model),
              ),
            ),
          ),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.commandFailed),
          onRetry: () => _sendDeviceCommand(device, command),
        );
      }
    } catch (_) {
      if (mounted) {
        showErrorSnackBar(
          context,
          l10n.commandFailed,
          onRetry: () => _sendDeviceCommand(device, command),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingCommand = false);
    }
  }

  Future<void> _toggleInternet(bool currentlyPaused, Device? device) async {
    final l10n = context.l10n;
    try {
      if (currentlyPaused) {
        await resumeInternet(ref, _childId);
      } else {
        await pauseInternet(ref, _childId);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.commandQueued(
                currentlyPaused ? l10n.commandResumeInternet : l10n.commandPauseInternet,
                device != null ? ltrIsolate(device.model) : l10n.scopeAllDevices,
              ),
            ),
            action: !currentlyPaused
                ? SnackBarAction(
                    label: l10n.undo,
                    onPressed: () => _toggleInternet(true, device),
                  )
                : null,
          ),
        );
      }
    } on ControlsRefusal catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e.error, () => l10n.commandFailed),
          onRetry: () => _toggleInternet(currentlyPaused, device),
        );
      }
    } catch (_) {
      if (mounted) {
        showErrorSnackBar(
          context,
          l10n.commandFailed,
          onRetry: () => _toggleInternet(currentlyPaused, device),
        );
      }
    }
  }

  Future<void> _grantBonus30() async {
    if (_grantingBonus) return;
    final l10n = context.l10n;
    setState(() => _grantingBonus = true);
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/$_childId/bonus',
        data: {'minutes': 30},
      );
      ref.invalidate(rulesProvider(_childId));
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.bonusGranted(30))),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.bonusFailed),
          onRetry: _grantBonus30,
        );
      }
    } catch (_) {
      if (mounted) {
        showErrorSnackBar(
          context,
          l10n.bonusFailed,
          onRetry: _grantBonus30,
        );
      }
    } finally {
      if (mounted) setState(() => _grantingBonus = false);
    }
  }

  static IconData _platformIcon(String platform) => switch (platform.toLowerCase()) {
        'android' => Icons.android,
        'ios' => Icons.apple,
        _ => Icons.devices_other,
      };

  @override
  Widget build(BuildContext context) {
    ref.watch(wsProvider);
    final l10n = context.l10n;
    final tokens = context.tokens;
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == _childId).firstOrNull;
    final devices = overview?.devicesFor(_childId) ?? const <Device>[];
    final selectedDevice = _resolveDevice(devices);
    final rules = ref.watch(rulesProvider(_childId)).valueOrNull;
    final geofences = ref.watch(geofencesProvider(_childId)).valueOrNull ?? const <Geofence>[];
    final internetPaused = ref.watch(internetPausedProvider(_childId)).valueOrNull ?? false;

    final displayName = child != null
        ? firstStrongIsolate(child.displayName)
        : l10n.childFallback;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('p08OverflowMenu'),
            onSelected: (value) {
              switch (value) {
                case 'rules':
                  context.push('/child/$_childId/rules');
                case 'reports':
                  context.push('/child/$_childId/reports');
                case 'searches':
                  context.push('/child/$_childId/searches');
                case 'commands':
                  context.push('/child/$_childId/commands');
                case 'consent':
                  context.push('/child/$_childId/consent');
                case 'pair':
                  context.push('/child/$_childId/pair');
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rules', child: Text(l10n.editRules)),
              PopupMenuItem(value: 'reports', child: Text(l10n.reportsTooltip)),
              PopupMenuItem(value: 'searches', child: Text(l10n.searchSafetyTooltip)),
              PopupMenuItem(value: 'commands', child: Text(l10n.deliveryStatus)),
              PopupMenuItem(value: 'consent', child: Text(l10n.parentalConsent)),
              PopupMenuItem(value: 'pair', child: Text(l10n.pairADevice)),
            ],
          ),
        ],
      ),
      body: overview == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(familyProvider);
                ref.invalidate(rulesProvider(_childId));
                ref.invalidate(geofencesProvider(_childId));
                if (selectedDevice != null) {
                  ref.invalidate(deviceCommandHistoryProvider(selectedDevice.id));
                }
              },
              child: SingleChildScrollView(
                key: const ValueKey('p08ScrollView'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppSpace.xl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (child != null) ...[
                      _TimeLeftHeaderCard(
                        child: child,
                        devices: devices,
                        selectedDevice: selectedDevice,
                        rules: rules,
                        internetPaused: internetPaused,
                        formatDuration: (m) => _formatDuration(context, m),
                        formatHHmm: _formatHHmm,
                        onSwitchDevice: selectedDevice != null && devices.length > 1
                            ? () => _switchDeviceSheet(devices, selectedDevice)
                            : null,
                        onMoreActions: selectedDevice != null
                            ? () => _openMoreActionsSheet(selectedDevice)
                            : null,
                        onOpenCommands: () => context.push('/child/$_childId/commands'),
                        onPairDevice: () => context.push('/child/$_childId/pair'),
                      ),
                      if (rulesFreshness(child, hasPairedDevice: devices.isNotEmpty) !=
                          RulesFreshness.current) ...[
                        const SizedBox(height: AppSpace.sm),
                        RulesBehindBanner(childId: _childId),
                      ],
                    ],
                    const SizedBox(height: AppSpace.md),
                    _EightRuleTilesGrid(
                      childId: _childId,
                      child: child,
                      devices: devices,
                      rules: rules,
                      geofences: geofences,
                      formatDuration: (m) => _formatDuration(context, m),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Text(
                      l10n.childOverviewQuickActions,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: tokens.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    _QuickActionsBar(
                      selectedDevice: selectedDevice,
                      internetPaused: internetPaused,
                      ringSent: _ringSent,
                      busy: _sendingCommand || _grantingBonus,
                      onLock: devices.isEmpty
                          ? null
                          : () => _lockAllDevices(devices),
                      onPauseNet: () => _toggleInternet(internetPaused, selectedDevice),
                      onRing: selectedDevice == null
                          ? null
                          : () => _sendDeviceCommand(
                                selectedDevice,
                                _ringSent ? 'stop_ring' : 'ring',
                              ),
                      onBonus30: _grantBonus30,
                    ),
                    if (selectedDevice != null) ...[
                      const SizedBox(height: AppSpace.sm),
                      _LastCommandProofBar(
                        device: selectedDevice,
                        onTap: () => context.push('/child/$_childId/commands'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _TimeLeftHeaderCard extends StatelessWidget {
  final Child child;
  final List<Device> devices;
  final Device? selectedDevice;
  final RuleSet? rules;
  final bool internetPaused;
  final String Function(int minutes) formatDuration;
  final String Function(DateTime ts) formatHHmm;
  final VoidCallback? onSwitchDevice;
  final VoidCallback? onMoreActions;
  final VoidCallback onOpenCommands;
  final VoidCallback onPairDevice;

  const _TimeLeftHeaderCard({
    required this.child,
    required this.devices,
    required this.selectedDevice,
    required this.rules,
    required this.internetPaused,
    required this.formatDuration,
    required this.formatHHmm,
    required this.onSwitchDevice,
    required this.onMoreActions,
    required this.onOpenCommands,
    required this.onPairDevice,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final textTheme = Theme.of(context).textTheme;

    final st = rules?.screenTime;
    final now = DateTime.now();
    final isWeekend = now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;
    // G5 (#1179): today's limit uses weekendLimitMinutes on Sat/Sun when > 0; never reads bonusMinutesToday.
    final limitMin = (isWeekend && (st?.weekendLimitMinutes ?? 0) > 0)
        ? st!.weekendLimitMinutes
        : (st?.dailyLimitMinutes ?? 0);
    final usedMin = child.screenTimeTodayMinutes;
    final isIphoneOnly = devices.isNotEmpty &&
        devices.every((d) => d.platform.toLowerCase() == 'ios');
    final hideIphoneEstimate = isIphoneOnly && usedMin == 0;
    final hasLimit = limitMin > 0 && !hideIphoneEstimate;
    final remainingMin = hasLimit ? (limitMin - usedMin).clamp(0, limitMin) : 0;
    final progress = hasLimit ? (usedMin / limitMin).clamp(0.0, 1.0) : 0.0;
    final barColor = !hasLimit
        ? tokens.primary
        : remainingMin == 0
            ? tokens.danger
            : progress >= 0.85
                ? tokens.warn
                : tokens.primary;

    final freshness = rulesFreshness(child, hasPairedDevice: devices.isNotEmpty);
    final proofTime = selectedDevice?.setup?.reportedAt ?? selectedDevice?.lastSeen;
    final String? proofLine = selectedDevice == null
        ? null
        : (freshness == RulesFreshness.current &&
                child.appliedRulesVersion != null &&
                proofTime != null)
            ? l10n.childOverviewAppliedOnAt(
                ltrIsolate(selectedDevice!.model),
                formatHHmm(proofTime),
              )
            : l10n.childOverviewSentToPhone;

    return Card(
      key: const ValueKey('p08TimeLeftCard'),
      color: tokens.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: tokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: tokens.primaryContainer,
                  foregroundColor: tokens.onPrimaryContainer,
                  child: Text(
                    child.initials,
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        firstStrongIsolate(child.displayName),
                        style: textTheme.titleMedium?.copyWith(
                          color: tokens.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpace.xxs),
                      Wrap(
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (selectedDevice != null)
                            Text(
                              '${selectedDevice!.isOnline ? l10n.statusOnline : l10n.statusOffline} · ${l10n.lastSeenLabel(formatLastSeen(context, selectedDevice!.lastSeen))}',
                              style: textTheme.bodySmall?.copyWith(
                                color: tokens.onSurfaceVariant,
                              ),
                            )
                          else
                            Text(
                              l10n.bornYear(child.birthYear),
                              style: textTheme.bodySmall?.copyWith(
                                color: tokens.onSurfaceVariant,
                              ),
                            ),
                          if (selectedDevice != null && selectedDevice!.batteryPct > 0)
                            Text(
                              l10n.childOverviewBatteryPct(
                                ltrIsolate('${selectedDevice!.batteryPct}'),
                              ),
                              style: textTheme.bodySmall?.copyWith(
                                color: selectedDevice!.batteryPct <= 20
                                    ? tokens.warn
                                    : tokens.onSurfaceVariant,
                              ),
                            ),
                          if (internetPaused)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpace.sm,
                                vertical: AppSpace.xxs,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.warn.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Text(
                                l10n.paused,
                                style: textTheme.labelSmall?.copyWith(
                                  color: tokens.warn,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            // Time-left headline & progress bar
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                Text(
                  hideIphoneEstimate
                      ? l10n.childOverviewNotYetAvailableIphone
                      : hasLimit
                          ? (remainingMin == 0
                              ? l10n.childOverviewTimeUp
                              : l10n.childOverviewTimeLeft(formatDuration(remainingMin)))
                          : '${l10n.childOverviewTodayUsed}: ${formatDuration(usedMin)}',
                  key: const ValueKey('p08TimeLeftHeadline'),
                  style: (hideIphoneEstimate ? textTheme.titleMedium : textTheme.headlineMedium)?.copyWith(
                    color: hideIphoneEstimate ? tokens.onSurfaceVariant : tokens.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hasLimit)
                  Text(
                    l10n.childOverviewOfLimit(formatDuration(limitMin)),
                    style: textTheme.bodyMedium?.copyWith(
                      color: tokens.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (hasLimit) ...[
              const SizedBox(height: AppSpace.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: tokens.surfaceVariant,
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Divider(height: 1, color: tokens.border),
            const SizedBox(height: AppSpace.sm),
            // Named device + Switch device (ONLY when devices.length > 1)
            if (selectedDevice != null) ...[
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _ChildOverviewP08ScreenState._platformIcon(
                          selectedDevice!.platform,
                        ),
                        size: 18,
                        color: tokens.primary,
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Flexible(
                        child: Text(
                          ltrIsolate(selectedDevice!.model),
                          key: const ValueKey('p08NamedDevice'),
                          style: textTheme.titleSmall?.copyWith(
                            color: tokens.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (onSwitchDevice != null)
                    TextButton.icon(
                      key: const ValueKey('p08SwitchDeviceButton'),
                      onPressed: onSwitchDevice,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: Text(l10n.childOverviewSwitchDevice),
                    ),
                  if (onMoreActions != null)
                    IconButton(
                      key: const ValueKey('p08DeviceMoreActionsButton'),
                      tooltip: l10n.deliveryStatus,
                      onPressed: onMoreActions,
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: const Icon(Icons.tune_outlined, size: 20),
                    ),
                ],
              ),
              if (proofLine != null) ...[
                const SizedBox(height: AppSpace.xs),
                InkWell(
                  key: const ValueKey('p08ProofLineTap'),
                  onTap: onOpenCommands,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          freshness == RulesFreshness.current &&
                                  child.appliedRulesVersion != null &&
                                  proofTime != null
                              ? Icons.check_circle_outline
                              : Icons.schedule,
                          size: 16,
                          color: freshness == RulesFreshness.current &&
                                  child.appliedRulesVersion != null &&
                                  proofTime != null
                              ? tokens.ok
                              : tokens.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppSpace.xs),
                        Expanded(
                          child: Text(
                            proofLine,
                            key: const ValueKey('p08ProofLine'),
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ] else ...[
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpace.sm,
                children: [
                  Text(
                    l10n.noDevicesRegistered,
                    style: textTheme.bodyMedium?.copyWith(
                      color: tokens.onSurfaceVariant,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onPairDevice,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.phonelink_setup, size: 18),
                    label: Text(l10n.pairADevice),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EightRuleTilesGrid extends StatelessWidget {
  final String childId;
  final Child? child;
  final List<Device> devices;
  final RuleSet? rules;
  final List<Geofence> geofences;
  final String Function(int minutes) formatDuration;

  const _EightRuleTilesGrid({
    required this.childId,
    required this.child,
    required this.devices,
    required this.rules,
    required this.geofences,
    required this.formatDuration,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final st = rules?.screenTime;
    final wf = rules?.webFilter;
    final appRules = rules?.appRules ?? const <AppRule>[];
    final blockedApps = appRules.where((a) => a.action == 'block').length;
    final limitedApps = appRules.where((a) => a.action == 'time_limit').length;
    final webOn = wf != null &&
        (wf.blockedCategories.isNotEmpty ||
            wf.safeSearchEnforced ||
            wf.blockedDomains.isNotEmpty);

    // Social monitoring: count active apps; if child has iOS-only devices, show Fix 8 wording.
    final isIphoneOnly = devices.isNotEmpty &&
        devices.every((d) => d.platform.toLowerCase() == 'ios');
    final monitoredSocialCount = rules == null
        ? 0
        : rules!.socialMonitoring.isEmpty
            ? kSocialApps.length
            : rules!.socialMonitoring.values.where((enabled) => enabled).length;

    final placeNames = geofences
        .take(3)
        .map((g) => firstStrongIsolate(g.label))
        .join(', ');

    final deviceModels = devices
        .take(2)
        .map((d) => ltrIsolate(d.model))
        .join(' · ');

    final tiles = <_OverviewTileData>[
      // 1. Daily limit
      _OverviewTileData(
        key: const ValueKey('p08Tile-dailyLimit'),
        icon: Icons.hourglass_bottom_outlined,
        title: l10n.childOverviewDailyLimitTitle,
        value: (st != null && st.dailyLimitMinutes > 0)
            ? formatDuration(st.dailyLimitMinutes)
            : l10n.childOverviewNoLimit,
        subtitle: (st != null && st.weekendLimitMinutes > 0)
            ? l10n.childOverviewWeekendsLimit(formatDuration(st.weekendLimitMinutes))
            : l10n.editRules,
        onTap: () => context.push('/child/$childId/rules'),
      ),
      // 2. Bedtime
      _OverviewTileData(
        key: const ValueKey('p08Tile-bedtime'),
        icon: Icons.bedtime_outlined,
        title: l10n.bedtime,
        value: (st != null && st.bedtimeStart.isNotEmpty)
            ? ltrIsolate(st.bedtimeStart)
            : l10n.off,
        subtitle: l10n.childOverviewSchoolNights,
        onTap: () => context.push('/child/$childId/rules'),
      ),
      // 3. Apps
      _OverviewTileData(
        key: const ValueKey('p08Tile-apps'),
        icon: Icons.apps_outlined,
        title: l10n.tabApps,
        value: l10n.childOverviewAppsBlockedCount(blockedApps),
        subtitle: l10n.childOverviewAppsWithLimits(limitedApps),
        onTap: () => context.push('/child/$childId/rules?tab=apps'),
      ),
      // 4. Web filter
      _OverviewTileData(
        key: const ValueKey('p08Tile-webFilter'),
        icon: Icons.public_outlined,
        title: l10n.tabWebFilter,
        value: webOn ? l10n.childOverviewWebFilterOn : l10n.off,
        subtitle: (wf?.safeSearchEnforced ?? false)
            ? l10n.childOverviewSafeSearchOn
            : l10n.childOverviewCategoriesBlocked(wf?.blockedCategories.length ?? 0),
        onTap: () => context.push('/child/$childId/rules'),
      ),
      // 5. Places
      _OverviewTileData(
        key: const ValueKey('p08Tile-places'),
        icon: Icons.place_outlined,
        title: l10n.alertCategoryGeofence,
        value: l10n.childOverviewPlacesSaved(geofences.length),
        subtitle: placeNames.isNotEmpty
            ? placeNames
            : l10n.childOverviewPlacesEmptySubtitle,
        onTap: () => context.push('/child/$childId?tab=location'),
      ),
      // 6. Social
      _OverviewTileData(
        key: const ValueKey('p08Tile-social'),
        icon: Icons.forum_outlined,
        title: l10n.tabSocial,
        value: isIphoneOnly
            ? l10n.off
            : l10n.childOverviewSocialAppsCount(monitoredSocialCount),
        subtitle: isIphoneOnly
            ? l10n.childOverviewNotYetAvailableIphone
            : (monitoredSocialCount > 0
                ? l10n.childOverviewCheckingMessages
                : l10n.socialOff),
        onTap: () => context.push('/child/$childId/social'),
      ),
      // 7. Devices
      _OverviewTileData(
        key: const ValueKey('p08Tile-devices'),
        icon: Icons.devices_outlined,
        title: l10n.devices,
        value: ltrIsolate('${devices.length}'),
        subtitle: deviceModels.isNotEmpty
            ? deviceModels
            : l10n.noDevicesRegistered,
        onTap: () => context.push('/child/$childId/commands'),
      ),
      // 8. This week (NO "−12%" delta per #1179!)
      _OverviewTileData(
        key: const ValueKey('p08Tile-thisWeek'),
        icon: Icons.insights_outlined,
        title: l10n.childOverviewThisWeekTitle,
        value: formatDuration(child?.screenTimeTodayMinutes ?? 0),
        subtitle: l10n.childOverviewUsageHistorySubtitle,
        onTap: () => context.push('/child/$childId/reports'),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        // At 320 px with 200% text scale, stack into 1 column so nothing overflows or truncates.
        final twoCols = constraints.maxWidth >= 300 &&
            !(constraints.maxWidth < 360 && textScale >= 1.8);
        if (!twoCols) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpace.sm),
                _RuleTileCard(data: tiles[i]),
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < tiles.length; i += 2) ...[
              if (i > 0) const SizedBox(height: AppSpace.sm),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _RuleTileCard(data: tiles[i])),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: i + 1 < tiles.length
                          ? _RuleTileCard(data: tiles[i + 1])
                          : const SizedBox.shrink(),
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

class _OverviewTileData {
  final Key key;
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final VoidCallback onTap;

  const _OverviewTileData({
    required this.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.onTap,
  });
}

class _RuleTileCard extends StatelessWidget {
  final _OverviewTileData data;
  const _RuleTileCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: data.key,
      margin: EdgeInsets.zero,
      color: tokens.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: tokens.border),
      ),
      child: InkWell(
        onTap: data.onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(data.icon, size: 18, color: tokens.primary),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        data.title,
                        style: textTheme.labelLarge?.copyWith(
                          color: tokens.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: tokens.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  data.value,
                  style: textTheme.titleLarge?.copyWith(
                    color: tokens.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpace.xxs),
                Text(
                  data.subtitle,
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActionsBar extends StatelessWidget {
  final Device? selectedDevice;
  final bool internetPaused;
  final bool ringSent;
  final bool busy;
  final VoidCallback? onLock;
  final VoidCallback onPauseNet;
  final VoidCallback? onRing;
  final VoidCallback onBonus30;

  const _QuickActionsBar({
    required this.selectedDevice,
    required this.internetPaused,
    required this.ringSent,
    required this.busy,
    required this.onLock,
    required this.onPauseNet,
    required this.onRing,
    required this.onBonus30,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    final buttons = <Widget>[
      _QuickActionTile(
        key: const ValueKey('p08QuickAction-lock'),
        icon: Icons.lock_outline,
        label: l10n.lock,
        onPressed: busy ? null : onLock,
      ),
      _QuickActionTile(
        key: const ValueKey('p08QuickAction-pauseNet'),
        icon: internetPaused ? Icons.wifi : Icons.wifi_off,
        label: internetPaused ? l10n.commandResumeInternet : l10n.commandPauseInternet,
        scopeHint: l10n.scopeAllDevices,
        highlighted: internetPaused,
        onPressed: busy ? null : onPauseNet,
      ),
      _QuickActionTile(
        key: const ValueKey('p08QuickAction-ring'),
        icon: ringSent ? Icons.notifications_off_outlined : Icons.notifications_active_outlined,
        label: ringSent ? l10n.commandStopRing : l10n.ring,
        highlighted: ringSent,
        onPressed: busy ? null : onRing,
      ),
      _QuickActionTile(
        key: const ValueKey('p08QuickAction-bonus30'),
        icon: Icons.more_time,
        label: l10n.childOverviewPlus30Min,
        onPressed: busy ? null : onBonus30,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        final cols = (constraints.maxWidth >= 360 && textScale < 1.5)
            ? 4
            : (constraints.maxWidth >= 268 && textScale < 1.9 ? 2 : 1);
        if (cols == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpace.sm),
                buttons[i],
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < buttons.length; i += cols) ...[
              if (i > 0) const SizedBox(height: AppSpace.sm),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = 0; j < cols; j++) ...[
                      if (j > 0) const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: i + j < buttons.length
                            ? buttons[i + j]
                            : const SizedBox.shrink(),
                      ),
                    ],
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

class _QuickActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? scopeHint;
  final bool highlighted;
  final VoidCallback? onPressed;

  const _QuickActionTile({
    super.key,
    required this.icon,
    required this.label,
    this.scopeHint,
    this.highlighted = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: highlighted ? tokens.primaryContainer : tokens.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: highlighted ? tokens.primary : tokens.border),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.md,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: onPressed == null
                      ? tokens.onSurfaceVariant
                      : (highlighted ? tokens.onPrimaryContainer : tokens.primary),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: textTheme.labelMedium?.copyWith(
                    color: onPressed == null
                        ? tokens.onSurfaceVariant
                        : (highlighted
                            ? tokens.onPrimaryContainer
                            : tokens.onSurface),
                  ),
                ),
                if (scopeHint != null) ...[
                  const SizedBox(height: AppSpace.xxs),
                  Text(
                    scopeHint!,
                    textAlign: TextAlign.center,
                    style: textTheme.labelSmall?.copyWith(
                      color: tokens.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LastCommandProofBar extends ConsumerWidget {
  final Device device;
  final VoidCallback onTap;

  const _LastCommandProofBar({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final history = ref.watch(deviceCommandHistoryProvider(device.id)).valueOrNull;
    if (history == null || history.isEmpty) return const SizedBox.shrink();
    final latest = history.first;
    final label = _commandLabel(l10n, latest.type);
    final statusDetail = switch (latest.status) {
      'acked' when latest.ackedAt != null =>
        l10n.confirmedEvent(formatCommandTime(context, latest.ackedAt)),
      'delivered' when latest.deliveredAt != null =>
        l10n.deliveredEvent(formatCommandTime(context, latest.deliveredAt)),
      _ => l10n.childOverviewSentToPhone,
    };
    return Card(
      key: const ValueKey('p08LastCommandProof'),
      margin: EdgeInsets.zero,
      color: tokens.surfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.receipt_long, size: 16, color: tokens.onSurfaceVariant),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  '$label · $statusDetail · ${ltrIsolate(device.model)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.onSurfaceVariant,
                      ),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: tokens.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

String _commandLabel(AppLocalizations l10n, String type) => switch (type) {
      'lock' => l10n.commandLock,
      'unlock' => l10n.unlock,
      'ring' => l10n.commandRing,
      'stop_ring' => l10n.commandStopRing,
      'pause' => l10n.commandPauseDevice,
      'pause_internet' => l10n.commandPauseInternet,
      'resume_internet' => l10n.commandResumeInternet,
      _ => type,
    };
