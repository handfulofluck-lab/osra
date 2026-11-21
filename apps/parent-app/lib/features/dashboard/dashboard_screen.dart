import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/digits.dart';
import '../../api/permission_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../widgets/field_question.dart';
import '../../providers/auth_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../auth/mfa_reset_approval_screen.dart';
import '../auth/mfa_reset_messages.dart';
import '../children/consent_step.dart';
import 'child_location_row.dart';

/// Parent dashboard: grid of child cards with live status, pull-to-refresh
/// and a consent-first "Add child" flow.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider);
    final unread = ref.watch(alertsBadgeCountProvider);
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
            // B3: count badge follows accessibility text scale up to 1.3x so
            // digits stay legible without overlapping the bell or neighbouring AppBar icons.
            icon: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
              ),
              child: Badge(
                isLabelVisible: unread.hasValue && (unread.value ?? 0) > 0,
                label: Text('${unread.value ?? 0}'),
                child: const Icon(Icons.notifications_outlined),
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => context.push(switch (v) {
              'family' => '/family',
              'appearance' => '/settings/appearance',
              'mfa' => '/settings/mfa',
              'delete-account' => '/settings/delete-account',
              _ => '/settings/digests',
            }),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'family', child: Text(l10n.familyMembersMenu)),
              PopupMenuItem(value: 'appearance', child: Text(l10n.appearanceMenu)),
              PopupMenuItem(value: 'digests', child: Text(l10n.digestPreferencesMenu)),
              PopupMenuItem(value: 'mfa', child: Text(l10n.mfaMenu)),
              PopupMenuItem(value: 'delete-account', child: Text(l10n.deleteAccountTitle)),
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
        error: (e, _) => ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.familyLoadFailed),
          onRetry: () => ref.invalidate(familyProvider),
        ),
        data: (overview) {
          final setupBanner = _finishSetupBanner(context, ref, overview);
          final banners = <Widget>[
            if (pendingResets.isNotEmpty) _pendingApprovalBanner(context, pendingResets),
            if (setupBanner != null) setupBanner,
          ];
          final isWide = MediaQuery.sizeOf(context).width >= 600;
          const listPadding = EdgeInsetsDirectional.only(
            start: AppSpace.md,
            end: AppSpace.md,
            top: AppSpace.md,
            bottom: AppSpace.xxl * 3, // 96 dp clearance for floating "add child" button
          );

          final content = overview.children.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 200),
                    Center(child: Text(l10n.noChildrenYet)),
                  ],
                )
              : !isWide
                  ? ListView.separated(
                      key: const ValueKey('dashboardCardsList'),
                      padding: listPadding,
                      itemCount: overview.children.length,
                      separatorBuilder: (_, __) => const SizedBox(height: AppSpace.md),
                      itemBuilder: (_, i) => ChildCard(child: overview.children[i]),
                    )
                  : ListView.separated(
                      key: const ValueKey('dashboardCardsList'),
                      padding: listPadding,
                      itemCount: (overview.children.length + 1) ~/ 2,
                      separatorBuilder: (_, __) => const SizedBox(height: AppSpace.md),
                      itemBuilder: (_, rowIndex) {
                        final children = overview.children;
                        final first = children[rowIndex * 2];
                        final secondIndex = rowIndex * 2 + 1;
                        final second = secondIndex < children.length ? children[secondIndex] : null;
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: ChildCard(child: first)),
                              const SizedBox(width: AppSpace.md),
                              Expanded(
                                child: second != null
                                    ? ChildCard(child: second)
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        );
                      },
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
      margin: const EdgeInsetsDirectional.fromSTEB(AppSpace.md, AppSpace.md, AppSpace.md, 0),
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
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final overview = ref.watch(familyProvider).valueOrNull;
    final device = overview?.devicesFor(child.id).firstOrNull;
    final locationValue = ref.watch(locationProvider(child.id));
    final location = locationValue.valueOrNull;
    // #406: a refused location read is not "no location yet" — the child card says so (Claude's ruling).
    final locationRefused = locationValue.hasError && ReadPermissionRequired.isRefusal(locationValue.error!);
    final places = location != null && !locationRefused
        ? ref.watch(geofencesProvider(child.id)).valueOrNull ?? const <Geofence>[]
        : const <Geofence>[];
    final rules = ref.watch(rulesProvider(child.id)).valueOrNull;
    final dailyLimit = rules?.screenTime.dailyLimitMinutes ?? 0;
    final progress = dailyLimit > 0 ? (child.screenTimeTodayMinutes / dailyLimit).clamp(0.0, 1.0) : 0.0;
    final live = ref.watch(liveActivityProvider)[child.id];
    final wellbeing = ref.watch(wellbeingProvider(child.id)).valueOrNull;

    final tokens = context.tokens;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/child/${child.id}'),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      CircleAvatar(child: Text(child.initials)),
                      const SizedBox(width: AppSpace.sm),
                      // B2: no line limit on dashboard card child names so cards expand cleanly.
                      Expanded(
                        child: Text(
                          child.displayName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
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
                      if (device != null)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(Icons.circle, size: 10, color: _statusColor(tokens, device.status)),
                          // #601: the server's word, not a local clock rule. There is no string for
                          // `locked`/`sos` (nothing in the API writes them today), so a value that is not
                          // `online` reads as `offline`.
                          label: Text(device.isOnline ? l10n.statusOnline : l10n.statusOffline),
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
                  ChildLocationRow(child: child, fix: location, places: places, refused: locationRefused),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (context) {
                      final style = Theme.of(context).textTheme.bodySmall;
                      final valueText = dailyLimit > 0
                          ? l10n.screenTimeValue(child.screenTimeTodayMinutes, dailyLimit)
                          : l10n.minutesShort(child.screenTimeTodayMinutes);
                      final screenWidth = MediaQuery.sizeOf(context).width;
                      final isWide = screenWidth >= 600;
                      // ListView horizontal padding (AppSpace.md * 2, plus AppSpace.md col gap on wide) + Card default margin (8) + Card padding (AppSpace.md * 2).
                      final maxContentWidth = isWide
                          ? (screenWidth - AppSpace.md * 3) / 2 - AppSpace.md * 2 - 8
                          : screenWidth - AppSpace.md * 4 - 8;
                      final scaler = MediaQuery.textScalerOf(context);
                      final direction = Directionality.of(context);
                      final labelPainter = TextPainter(
                        text: TextSpan(text: l10n.screenTime, style: style),
                        maxLines: 1,
                        textDirection: direction,
                        textScaler: scaler,
                      )..layout();
                      final labelWidth = labelPainter.width;
                      labelPainter.dispose();
                      final valuePainter = TextPainter(
                        text: TextSpan(text: valueText, style: style),
                        maxLines: 1,
                        textDirection: direction,
                        textScaler: scaler,
                      )..layout();
                      final valueWidth = valuePainter.width;
                      valuePainter.dispose();
                      if (labelWidth + AppSpace.sm + valueWidth <= maxContentWidth) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(l10n.screenTime, style: style),
                            const SizedBox(width: AppSpace.sm),
                            Flexible(child: Text(valueText, style: style, textAlign: TextAlign.end)),
                          ],
                        );
                      }
                      // NOTE: stack end-aligned when tight so neither label nor value truncates with ellipsis at high scale.
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.screenTime, style: style),
                          const SizedBox(height: AppSpace.xs),
                          Text(valueText, style: style, textAlign: TextAlign.end),
                        ],
                      );
                    },
                  ),
                  if (dailyLimit > 0) ...[
                    const SizedBox(height: AppSpace.xs),
                    LinearProgressIndicator(value: progress),
                  ],
                  if (wellbeing != null) ...[
                    const SizedBox(height: AppSpace.sm),
                    WellbeingRow(score: wellbeing),
                  ],
                ],
              ),
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
          // NOTE: flexible without ellipsis — wraps cleanly on 320px cards at 2.0 scale.
          Flexible(child: Text(l10n.wellbeingScore(score.score), style: Theme.of(context).textTheme.bodySmall)),
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
      scrollable: true,
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
  } on ControlsRefusal catch (r) {
    // #441 review: the pill is the main entry to pause/resume, so it needs the same sentence as the
    // device card — and it must not print `ControlsRefusal(428)`, which is what '$e' became.
    if (context.mounted) {
      showErrorSnackBar(
        context,
        friendlyErrorText(l10n, r.error, () => l10n.internetChangeFailed),
      );
    }
  } catch (e) {
    if (context.mounted) {
      showErrorSnackBar(
        context,
        friendlyErrorText(l10n, e, () => l10n.internetChangeFailed),
      );
    }
  }
}

/// Two-step add-child dialog: parental consent first (method + jurisdiction
/// matching the family region), then the child's details.
/// Issue #437 review: the one consent refusal a *creation* dialog can act on. The child does not exist
/// yet, so "open Parental consent on the child's page" would point at a page that is not there — the
/// fix is the dialog's own region dropdown, and the sentence names the region the server expected.
String? addChildConsentRegionError(AppLocalizations l10n, DioException e) {
  final region = consentRefusalRegionLabel(l10n, e);
  return region == null ? null : l10n.addChildConsentRegion(region);
}

class AddChildDialog extends ConsumerStatefulWidget {
  const AddChildDialog({super.key});

  @override
  ConsumerState<AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends ConsumerState<AddChildDialog> {
  final _name = TextEditingController();
  final _birthYear = TextEditingController();
  String _method = kConsentMethods.first;
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
        'birthYear': int.tryParse(normalizeDigits(_birthYear.text.trim())) ?? DateTime.now().year,
        'consent': {'method': _method, 'jurisdiction': _jurisdiction},
      });
      ref.invalidate(familyProvider);
      if (mounted) Navigator.of(context).pop();
    } on DioException catch (e) {
      // Issue #437 review: this is child *creation*, so the child's own Parental consent page does not
      // exist yet — the generic consent sentences would point at a page that is not there. The one case
      // worth a sentence is the region mismatch, because the dialog has a region dropdown and the fix
      // is to pick the family's.
      setState(() => _error = addChildConsentRegionError(context.l10n, e) ??
          friendlyErrorText(context.l10n, e, () => context.l10n.onboardingChildFailed));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(_consentDone ? l10n.childDetails : l10n.parentalConsent),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
            if (!_consentDone) ...[
              // The notice and the method picker are shared with the consent
              // screen's "give consent again" action (#437 part B), so the
              // wording cannot drift between the two places a parent consents.
              ConsentStep(
                method: _method,
                onMethodChanged: (m) => setState(() => _method = m),
              ),
              const SizedBox(height: AppSpace.md),
              FieldQuestion(
                text: l10n.jurisdictionLabel,
                child: DropdownButtonFormField<String>(
                key: const ValueKey('addChildJurisdiction'),
                initialValue: _jurisdiction,
                // #874 B6 (UI/UX Bureau): `isExpanded` false sized the button to its widest item, so at
                // 200 % text the field overflowed by 27 px (82 px at 320 px / 200 %). Expanded, the label
                // is laid out inside the field; the `selectedItemBuilder` below lets it wrap there instead
                // of being cut, which is what «رسالة نصية مع تأكيد» needed on the consent-method field.
                isExpanded: true,
                // #874: the default `isDense: true` caps the field at 48 px and clips the wrapped
                // selected value at AR 320 / 200 % (Arabic Language Bureau's frame).
                isDense: false,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: [
                  DropdownMenuItem(value: 'US', child: Text(l10n.regionUS)),
                  DropdownMenuItem(value: 'EU', child: Text(l10n.regionEU)),
                  DropdownMenuItem(value: 'UK', child: Text(l10n.regionUK)),
                  DropdownMenuItem(value: 'OTHER', child: Text(l10n.regionOther)),
                ],
                // Same order as `items`: the family region is a place name, so the selected value may take
                // two lines rather than one line with an ellipsis.
                selectedItemBuilder: (context) => [
                  Text(l10n.regionUS),
                  Text(l10n.regionEU),
                  Text(l10n.regionUK),
                  Text(l10n.regionOther),
                ],
                onChanged: (v) => setState(() => _jurisdiction = v ?? 'US'),
                ),
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
