import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../api/permission_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../auth/mfa_reset_approval_screen.dart';
import '../auth/mfa_reset_messages.dart';

/// Parent dashboard: grid of child cards with live status, pull-to-refresh
/// and a consent-first "Add child" flow.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider);
    final unread = ref.watch(unacknowledgedCountProvider);
    // ADR-0031 step 3b: a signed-in owner/co-parent is told on open that
    // someone needs a witness. A guardian's 403 becomes an empty list in the
    // provider, so this is absent rather than an error.
    final pendingResets = ref.watch(mfaResetPendingProvider).valueOrNull ?? const <MfaResetPendingRequest>[];
    final l10n = context.l10n;
    // Keep the live WS channel subscribed so the activity chips update (#29).
    ref.watch(wsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appName),
        actions: [
          IconButton(icon: const Icon(Icons.map_outlined), tooltip: l10n.familyMapTooltip, onPressed: () => context.push('/map')),
          IconButton(
            tooltip: l10n.alertsTooltip,
            onPressed: () => context.push('/alerts'),
            icon: Badge(
              isLabelVisible: unread.hasValue && (unread.value ?? 0) > 0,
              label: Text('${unread.value ?? 0}'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => context.push(switch (v) {
              'family' => '/family',
              'appearance' => '/settings/appearance',
              'mfa' => '/settings/mfa',
              _ => '/settings/digests',
            }),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'family', child: Text(l10n.familyMembersMenu)),
              PopupMenuItem(value: 'appearance', child: Text(l10n.appearanceMenu)),
              PopupMenuItem(value: 'digests', child: Text(l10n.digestPreferencesMenu)),
              PopupMenuItem(value: 'mfa', child: Text(l10n.mfaMenu)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.signOutTooltip,
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
      body: family.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l10n.familyLoadFailed('$e'))),
        data: (overview) {
          final setupBanner = _finishSetupBanner(context, ref, overview);
          final banners = <Widget>[
            if (pendingResets.isNotEmpty) _pendingApprovalBanner(context, pendingResets),
            if (setupBanner != null) setupBanner,
          ];
          final content = overview.children.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 200),
                    Center(child: Text(l10n.noChildrenYet)),
                  ],
                )
              : GridView.count(
                  // NOTE: one column under 400px — two 110px-wide cards made
                  // the card content overflow on 320px-wide screens.
                  crossAxisCount: MediaQuery.sizeOf(context).width < 400 ? 1 : 2,
                  padding: const EdgeInsets.all(AppSpace.md),
                  mainAxisSpacing: AppSpace.md,
                  crossAxisSpacing: AppSpace.md,
                  children: [for (final child in overview.children) ChildCard(child: child)],
                );
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(familyProvider);
              ref.invalidate(mfaResetPendingProvider);
            },
            child: banners.isEmpty
                ? content
                : Column(
                    children: [
                      ...banners,
                      Expanded(child: content),
                    ],
                  ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog(context: context, builder: (_) => const AddChildDialog()),
        icon: const Icon(Icons.person_add),
        label: Text(l10n.addChild),
      ),
    );
  }

  /// A family reset request that needs this parent's witness, with the
  /// requester's name from `GET /v1/auth/mfa/reset/pending`. The prompt exists
  /// only when the list is non-empty, so a guardian and an empty family see
  /// nothing at all.
  Widget _pendingApprovalBanner(BuildContext context, List<MfaResetPendingRequest> requests) {
    final l10n = context.l10n;
    final first = requests.first;
    final name = first.requesterName.trim().isEmpty ? l10n.mfaResetRoleFamilyMember : first.requesterName;
    final role = mfaResetRoleName(l10n, first.requesterRole);
    return Card(
      margin: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.md, AppSpace.md, 0),
      child: ListTile(
        key: const ValueKey('mfaResetPendingBanner'),
        leading: const Icon(Icons.lock_reset),
        title: Text(l10n.mfaResetPendingBanner(name, role.isEmpty ? l10n.mfaResetRoleFamilyMember : role)),
        subtitle: requests.length > 1 ? Text(l10n.mfaResetPendingMore(requests.length - 1)) : null,
        trailing: TextButton(
          key: const ValueKey('mfaResetPendingReview'),
          onPressed: () => _openApproval(context, first),
          child: Text(l10n.mfaResetPendingReview),
        ),
        onTap: () => _openApproval(context, first),
      ),
    );
  }

  /// Opens the approval prompt with the id and name the pending list gave us.
  void _openApproval(BuildContext context, MfaResetPendingRequest request) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MfaResetApprovalScreen(
        requestId: request.requestId,
        requesterName: request.requesterName,
        requesterRole: request.requesterRole,
        pendingState: request.state,
        pendingWindowEndsAt: request.windowEndsAt,
      ),
    ));
  }

  /// Persistent "finish setting up" affordance after the wizard was completed
  /// with pairing skipped. It disappears once the server reports a device.
  Widget? _finishSetupBanner(BuildContext context, WidgetRef ref, FamilyOverview overview) {
    final onboarding = ref.watch(onboardingProvider);
    final childId = onboarding.childId;
    if (!onboarding.pairingPending || childId == null) return null;
    Child? child;
    for (final candidate in overview.children) {
      if (candidate.id == childId) child = candidate;
    }
    if (child == null) return null;
    if (overview.devicesFor(child.id).isNotEmpty) return null;

    final l10n = context.l10n;
    final tokens = context.tokens;
    return Card(
      key: const ValueKey('finishSetupBanner'),
      margin: const EdgeInsetsDirectional.fromSTEB(AppSpace.md, AppSpace.md, AppSpace.md, 0),
      color: tokens.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.onboardingFinishSetupTitle, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.xs),
            Text(l10n.onboardingFinishSetupBody(child.displayName), style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                key: const ValueKey('finishSetupPairNow'),
                onPressed: () => _openPairing(context, ref, child!),
                child: Text(l10n.onboardingPairNow),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPairing(BuildContext context, WidgetRef ref, Child child) async {
    await context.push('/child/${child.id}/pair');
    if (!context.mounted) return;
    ref.invalidate(familyProvider);
    try {
      final overview = await ref.read(familyProvider.future);
      if (overview.devicesFor(child.id).isNotEmpty) {
        await ref.read(onboardingProvider.notifier).clearPairingPending();
      }
    } catch (_) {
      // The banner stays; the dashboard's retry path is the refresh gesture.
    }
  }
}

/// Grid card for one child: avatar, status pill, battery, location snippet
/// and today's screen-time progress against the daily limit.
class ChildCard extends ConsumerWidget {
  final Child child;
  const ChildCard({super.key, required this.child});

  Color _statusColor(AppTokens tokens, String status) => switch (status) {
        'online' => tokens.ok,
        'locked' => tokens.warn,
        'sos' => tokens.danger,
        _ => tokens.onSurfaceVariant,
      };

  /// Online when the device checked in within [kDeviceOnlineWindow].
  static String _effectiveStatus(Device d) => isDeviceOnline(d.lastSeen) ? 'online' : 'offline';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final overview = ref.watch(familyProvider).valueOrNull;
    final device = overview?.devicesFor(child.id).firstOrNull;
    final locationValue = ref.watch(locationProvider(child.id));
    final location = locationValue.valueOrNull;
    // #406: a refused location read is not "no location yet" — the child card says so (Claude's ruling).
    final locationRefused = locationValue.hasError && ReadPermissionRequired.isRefusal(locationValue.error!);
    final rules = ref.watch(rulesProvider(child.id)).valueOrNull;
    final dailyLimit = rules?.screenTime.dailyLimitMinutes ?? 0;
    final progress = dailyLimit > 0 ? (child.screenTimeTodayMinutes / dailyLimit).clamp(0.0, 1.0) : 0.0;
    final live = ref.watch(liveActivityProvider)[child.id];
    final wellbeing = ref.watch(wellbeingProvider(child.id)).valueOrNull;

    final tokens = context.tokens;
    final status = device == null ? null : _effectiveStatus(device);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/child/${child.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(child: Text(child.initials)),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: Text(child.displayName, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
                ],
              ),
              if (live != null && live.isFresh()) ...[
                const SizedBox(height: AppSpace.xs),
                LiveActivityChip(childId: child.id, activity: live),
              ],
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (device != null && status != null)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(Icons.circle, size: 10, color: _statusColor(tokens, status)),
                      label: Text(status == 'online' ? l10n.statusOnline : l10n.statusOffline),
                    ),
                  if (device != null && device.batteryPct > 0)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(device.batteryPct <= 20 ? Icons.battery_alert : Icons.battery_std, size: 14),
                      label: Text('${device.batteryPct}%'),
                    ),
                  InternetPill(child: child),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  const Icon(Icons.location_on_outlined, size: 14),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      // #406: a refusal names the owner; "no location yet" would read as a normal state.
                      locationRefused
                          ? l10n.readPermissionRequired
                          : location == null
                              ? l10n.noLocationYet
                              : '${location.lat.toStringAsFixed(4)}, ${location.lng.toStringAsFixed(4)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.screenTime, style: Theme.of(context).textTheme.bodySmall),
                  // NOTE: flexible + ellipsis — narrow cards overflowed this row.
                  Flexible(
                    child: Text(l10n.screenTimeValue(child.screenTimeTodayMinutes, dailyLimit > 0 ? dailyLimit : 0),
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              LinearProgressIndicator(value: dailyLimit > 0 ? progress : null),
              if (wellbeing != null) ...[
                const SizedBox(height: AppSpace.sm),
                WellbeingRow(score: wellbeing),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Feature #29 chip: '● {app} · {minutesToday}m today', green while a
/// `live_activity` WS event is fresh (< 2 min); tapping opens the child detail.
class LiveActivityChip extends StatelessWidget {
  final String childId;
  final LiveActivity activity;
  const LiveActivityChip({super.key, required this.childId, required this.activity});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => context.push('/child/$childId'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
        child: Text(
          '● ${context.l10n.liveActivityToday(activity.app, activity.minutesToday)}',
          key: ValueKey('liveChip-$childId'),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tokens.ok),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Feature #28: compact wellbeing score ring (score/100, red < 50, amber < 75,
/// green otherwise) with a tooltip breakdown of the sub-scores.
class WellbeingRow extends StatelessWidget {
  final WellbeingScore score;
  const WellbeingRow({super.key, required this.score});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l10n = context.l10n;
    // Legacy rings keep their pinned Material thresholds (Colors.red/amber/
    // green in light mode) through the token layer, so the colours can differ
    // per brightness without changing the documented thresholds.
    final color = score.score < 50
        ? tokens.wellbeingLow
        : score.score < 75
            ? tokens.wellbeingMid
            : tokens.wellbeingHigh;
    final breakdown = score.breakdown;
    String part(String label, String k) => '$label: ${breakdown[k] ?? '—'}';
    return Tooltip(
      message: '${part(l10n.wellbeingUsage, 'usage')} · ${part(l10n.wellbeingSocial, 'social')} · '
          '${part(l10n.wellbeingSafety, 'safety')}',
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: (score.score / 100).clamp(0.0, 1.0),
                  strokeWidth: 4,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.15),
                ),
                Text(
                  '${score.score}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        height: 1,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          // NOTE: flexible — the row overflowed 320px-wide cards.
          Flexible(child: Text(l10n.wellbeingScore(score.score), style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// One-tap "pause the internet" pill (Feature #11): red "Paused" when the
/// child's internet is sinkholed, green "Internet" otherwise. Tapping toggles
/// via a confirm dialog; the flip is optimistic and reverts on error.
class InternetPill extends ConsumerWidget {
  final Child child;
  const InternetPill({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(internetPausedProvider(child.id)).valueOrNull ?? false;
    final tokens = context.tokens;
    final color = paused ? tokens.danger : tokens.ok;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => toggleInternetWithConfirm(context, ref, child, paused),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(paused ? Icons.wifi_off : Icons.wifi, size: 14, color: color),
            const SizedBox(width: AppSpace.xs),
            Text(paused ? context.l10n.paused : context.l10n.internet, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// Family Link style confirm dialog for the internet pill; POSTs the toggle
/// only on confirm.
Future<void> toggleInternetWithConfirm(BuildContext context, WidgetRef ref, Child child, bool paused) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(paused ? l10n.resumeInternetTitle(child.displayName) : l10n.pauseInternetTitle(child.displayName)),
      content: Text(paused ? l10n.resumeInternetBody : l10n.pauseInternetBody),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(paused ? l10n.resume : l10n.pause)),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    if (paused) {
      await resumeInternet(ref, child.id);
    } else {
      await pauseInternet(ref, child.id);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.internetChangeFailed('$e'))));
    }
  }
}

/// Two-step add-child dialog: parental consent first (method + jurisdiction
/// matching the family region), then the child's details.
class AddChildDialog extends ConsumerStatefulWidget {
  const AddChildDialog({super.key});

  @override
  ConsumerState<AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends ConsumerState<AddChildDialog> {
  static const _methods = ['sms_plus', 'kba', 'face_match', 'credit_card'];
  final _name = TextEditingController();
  final _birthYear = TextEditingController();
  String _method = _methods.first;
  late String _jurisdiction;
  bool _consentDone = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _jurisdiction = ref.read(authProvider).family?.region ?? 'US';
  }

  @override
  void dispose() {
    _name.dispose();
    _birthYear.dispose();
    super.dispose();
  }

  /// Advance from the consent step to the child-details step. The consent is
  /// submitted together with the child in [_createChild] (single atomic POST).
  void _recordConsent() => setState(() => _consentDone = true);

  Future<void> _createChild() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).raw.post('/v1/family/children', data: {
        'displayName': _name.text.trim(),
        'birthYear': int.tryParse(_birthYear.text.trim()) ?? DateTime.now().year,
        'consent': {'method': _method, 'jurisdiction': _jurisdiction},
      });
      ref.invalidate(familyProvider);
      if (mounted) Navigator.of(context).pop();
    } on DioException catch (e) {
      // Consent gate: surface the API's 428 message when consent is missing.
      final data = e.response?.data;
      setState(() => _error = data is Map ? '${data['error'] ?? data['message'] ?? e.message}' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(_consentDone ? l10n.childDetails : l10n.parentalConsent),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_consentDone) ...[
              // TODO(#159): legal consent wording needs a product/legal
              // decision before it can be translated; it stays English.
              Text(l10n.consentNotice),
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: InputDecoration(labelText: l10n.consentMethodLabel, border: const OutlineInputBorder()),
                items: [for (final m in _methods) DropdownMenuItem(value: m, child: Text(l10n.consentMethod(m)))],
                onChanged: (v) => setState(() => _method = v ?? _methods.first),
              ),
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _jurisdiction,
                decoration: InputDecoration(labelText: l10n.jurisdictionLabel, border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem(value: 'US', child: Text(l10n.regionUS)),
                  DropdownMenuItem(value: 'EU', child: Text(l10n.regionEU)),
                  DropdownMenuItem(value: 'UK', child: Text(l10n.regionUK)),
                  DropdownMenuItem(value: 'OTHER', child: Text(l10n.regionOther)),
                ],
                onChanged: (v) => setState(() => _jurisdiction = v ?? 'US'),
              ),
            ] else ...[
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: l10n.childNameLabel, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _birthYear,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.birthYearLabel,
                  border: const OutlineInputBorder(),
                  hintText: '${DateTime.now().year}',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(_error!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(
          onPressed: _busy ? null : (_consentDone ? _createChild : _recordConsent),
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_consentDone ? l10n.addChild : l10n.continueLabel),
        ),
      ],
    );
  }
}

/// Formats a device last-seen timestamp for display in the app locale.
String formatLastSeen(BuildContext context, DateTime? lastSeen) => lastSeen == null
    ? context.l10n.never
    : DateFormat.yMMMd(context.localeName).add_Hm().format(lastSeen.toLocal());

/// How long after its last check-in a device still shows as online (roadmap 5.8, #353).
///
/// An idle phone that the server can wake by push polls every 10 minutes, and each poll refreshes
/// `lastSeen` once it is 5 minutes old, so a healthy idle phone is at most about 10 minutes behind.
/// The old 3 minutes turned such a phone grey most of the time. 15 minutes keeps one late poll
/// green; a phone that really stopped is reported by the silent-device alert (30 minutes).
const Duration kDeviceOnlineWindow = Duration(minutes: 15);

/// True when [lastSeen] is within [kDeviceOnlineWindow] of [now] (the current time by default).
bool isDeviceOnline(DateTime? lastSeen, {DateTime? now}) =>
    lastSeen != null && (now ?? DateTime.now()).difference(lastSeen) < kDeviceOnlineWindow;
