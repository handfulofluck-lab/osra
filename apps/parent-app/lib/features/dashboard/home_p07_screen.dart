import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/pairing_session_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../alerts/alerts_screen.dart';
import '../alerts/app_alert_presentation.dart';
import '../settings/settings_screen.dart' show p22SettingsEnabledProvider;
import '../alerts/time_request_actions.dart';
import '../auth/mfa_reset_approval_screen.dart';
import '../auth/mfa_reset_messages.dart';
import '../family/family_screen.dart';
import '../map/child_location_view.dart';
import '../pairing/pair_qr_screen.dart' show pairClaimDeviceLabel;
import '../rules/active_window.dart';
import 'dashboard_screen.dart' show AddChildDialog;

/// Feature switch for UX Final Decisions P-07 Home + P-07-RTL (#1179).
///
/// Enable at build time via `--dart-define=OSRA_UX_P07=true` or
/// `--dart-define=OSRA_UX_FINAL=true`, or override [p07HomeEnabledProvider] in
/// widget tests. When `false`, `DashboardScreen` renders the legacy fallback.
const bool kEnableUxP07Home = bool.fromEnvironment(
  'OSRA_UX_P07',
  defaultValue: bool.fromEnvironment('OSRA_UX_FINAL', defaultValue: false),
);

final p07HomeEnabledProvider = Provider<bool>((ref) => kEnableUxP07Home);

final p07BonusHoldDurationProvider =
    Provider<Duration>((ref) => const Duration(seconds: 5));

String _arabicDualGenitive(String s) =>
    s.replaceAll('ساعتان', 'ساعتين').replaceAll('دقيقتان', 'دقيقتين');

String formatHomeDuration(
  AppLocalizations l10n,
  int totalMinutes, {
  bool genitive = false,
}) {
  final clamped = totalMinutes < 0 ? 0 : totalMinutes;
  final h = clamped ~/ 60;
  final m = clamped % 60;
  final String raw;
  if (h > 0 && m > 0) {
    raw = l10n.homeDurationHoursMinutes(
      l10n.hoursShort(h),
      l10n.minutesShort(m),
    );
  } else if (h > 0) {
    raw = l10n.hoursShort(h);
  } else {
    raw = l10n.minutesShort(m);
  }
  return genitive ? _arabicDualGenitive(raw) : raw;
}

String _formatRelativeAgo(AppLocalizations l10n, Duration age) {
  final mins = age.isNegative ? 0 : age.inMinutes;
  if (mins < 1) return l10n.relativeJustNow;
  if (mins < 60) return l10n.relativeMinutesAgo(mins);
  final hours = mins ~/ 60;
  if (hours < 24) return l10n.relativeHoursAgo(hours);
  return l10n.relativeDaysAgo(hours ~/ 24);
}

String formatHomeElapsed(
  AppLocalizations l10n,
  Duration age, {
  bool genitive = false,
}) {
  final mins = age.inMinutes < 1 ? 1 : age.inMinutes;
  final raw = mins < 60
      ? l10n.minutesShort(mins)
      : l10n.hoursShort(age.inHours < 1 ? 1 : age.inHours);
  return genitive ? _arabicDualGenitive(raw) : raw;
}

@immutable
class HomeTimeSummary {
  final int usedMinutes;
  final int effectiveLimitMinutes;
  final int remainingMinutes;
  final double progress;

  const HomeTimeSummary({
    required this.usedMinutes,
    required this.effectiveLimitMinutes,
    required this.remainingMinutes,
    required this.progress,
  });
}

/// Computes P-07 daily time-left from today's base limit plus today's `acked`
/// `bonus_time` rows in [primaryDeviceHistory] (ignoring `ruleSet.bonusMinutesToday`,
/// which never resets across days on the server).
///
/// Window note (G5): `deviceCommandHistoryProvider` reads up to 100 recent
/// commands (the server's `listDeviceCommands` cap). If more than 100 commands
/// are issued to the same device in one day so an earlier same-day `acked`
/// grant ages past [primaryDeviceHistory], `effectiveLimitMinutes` conservatively
/// omits that aged-out grant and clamps `remainingMinutes` at `0` rather than
/// over-reporting from stale `bonusMinutesToday`.
HomeTimeSummary computeHomeTimeSummary({
  required int usedMinutes,
  required RuleSet? rules,
  required DateTime now,
  required int? utcOffsetMinutes,
  required Iterable<DeviceCommand> primaryDeviceHistory,
}) {
  final wallNow = familyWallClock(now, utcOffsetMinutes);
  final isWeekend = wallNow.weekday == DateTime.saturday ||
      wallNow.weekday == DateTime.sunday;
  final baseLimit = rules == null
      ? 0
      : (isWeekend && rules.screenTime.weekendLimitMinutes > 0
          ? rules.screenTime.weekendLimitMinutes
          : rules.screenTime.dailyLimitMinutes);

  var ackedBonusToday = 0;
  for (final cmd in primaryDeviceHistory) {
    if (cmd.type != 'bonus_time' || cmd.status != 'acked') continue;
    final stamp = cmd.ackedAt ?? cmd.createdAt;
    if (stamp == null) continue;
    final wallStamp = familyWallClock(stamp, utcOffsetMinutes);
    if (wallStamp.year == wallNow.year &&
        wallStamp.month == wallNow.month &&
        wallStamp.day == wallNow.day) {
      final raw = cmd.payload?['minutes'];
      final mins = raw is int
          ? raw
          : (raw is num
              ? raw.toInt()
              : int.tryParse(raw?.toString() ?? '') ?? 0);
      if (mins > 0) ackedBonusToday += mins;
    }
  }

  final effectiveLimit = baseLimit > 0 ? baseLimit + ackedBonusToday : 0;
  final safeUsed = usedMinutes < 0 ? 0 : usedMinutes;
  final remaining =
      effectiveLimit > safeUsed ? effectiveLimit - safeUsed : 0;
  final progress = effectiveLimit > 0
      ? (safeUsed / effectiveLimit).clamp(0.0, 1.0)
      : 0.0;
  return HomeTimeSummary(
    usedMinutes: safeUsed,
    effectiveLimitMinutes: effectiveLimit,
    remainingMinutes: remaining,
    progress: progress,
  );
}

bool _inClockWindow(int minutesOfDay, String start, String end) {
  int? parse(String v) {
    final parts = v.trim().split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return h * 60 + m;
  }

  final s = parse(start);
  final e = parse(end);
  if (s == null || e == null) return false;
  if (s <= e) return minutesOfDay >= s && minutesOfDay < e;
  return minutesOfDay >= s || minutesOfDay < e;
}

String resolveHomeChildStateLabel({
  required AppLocalizations l10n,
  required bool pausedOrLocked,
  required RuleSet? rules,
  required DateTime now,
  required int? utcOffsetMinutes,
}) {
  if (pausedOrLocked) return l10n.homeStatePaused;
  if (rules == null) return l10n.homeStateFreeTime;
  final wallNow = familyWallClock(now, utcOffsetMinutes);
  final day = wallNow.weekday;
  final mins = wallNow.hour * 60 + wallNow.minute;

  for (final routine in rules.routines) {
    if (!routine.days.contains(day)) continue;
    if (!_inClockWindow(mins, routine.startTime, routine.endTime)) continue;
    final lower = routine.name.trim().toLowerCase();
    if (lower == 'homework' || routine.name.contains('واجب')) {
      return l10n.homeStateHomework;
    }
    if (routine.name.trim().isNotEmpty) {
      return firstStrongIsolate(routine.name.trim());
    }
  }
  if (_inClockWindow(
    mins,
    rules.screenTime.bedtimeStart,
    rules.screenTime.bedtimeEnd,
  )) {
    return l10n.homeStateBedtime;
  }
  if (rules.screenTime.schoolDays.contains(day) &&
      _inClockWindow(
        mins,
        rules.screenTime.schoolStart,
        rules.screenTime.schoolEnd,
      )) {
    return l10n.homeStateAtSchool;
  }
  return l10n.homeStateFreeTime;
}

class HomeP07PreviewTile extends StatelessWidget {
  final String initials;
  final String childName;
  final String stateLabel;
  final String timeLeftText;
  final double progress;
  final bool showExampleBadge;

  const HomeP07PreviewTile({
    super.key,
    required this.initials,
    required this.childName,
    required this.stateLabel,
    required this.timeLeftText,
    required this.progress,
    this.showExampleBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final l10n = context.l10n;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showExampleBadge) ...[
              Container(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: AppSpace.sm,
                  vertical: AppSpace.xxs,
                ),
                decoration: BoxDecoration(
                  color: tokens.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: tokens.border),
                ),
                child: Text(
                  l10n.homeExampleBadge,
                  style: text.labelSmall?.copyWith(
                    color: tokens.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.xs),
            ],
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: tokens.primaryContainer,
                  foregroundColor: tokens.onPrimaryContainer,
                  child: Text(initials, style: text.labelMedium),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    firstStrongIsolate(childName),
                    style: text.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              stateLabel,
              style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(timeLeftText, style: text.labelMedium),
            const SizedBox(height: AppSpace.xxs),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 6,
                color: tokens.primary,
                backgroundColor: tokens.surfaceContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeP07Screen extends ConsumerStatefulWidget {
  const HomeP07Screen({super.key});

  @override
  ConsumerState<HomeP07Screen> createState() => _HomeP07ScreenState();
}

class _HomeP07ScreenState extends ConsumerState<HomeP07Screen> {
  int _tabIndex = 0;
  String? _selectedChildId;
  final Map<String, Alert> _resolvedTimeRequests = <String, Alert>{};

  @override
  Widget build(BuildContext context) {
    ref.watch(wsProvider);
    final unread = ref.watch(alertsBadgeCountProvider);
    final badgeCount = unread.valueOrNull ?? 0;

    return Scaffold(
      appBar: _tabIndex == 0
          ? _buildHomeAppBar(context)
          : _tabIndex == 3
              ? AppBar(title: Text(context.l10n.homeTabSettings))
              : null,
      body: switch (_tabIndex) {
        0 => _buildHomeBody(context),
        1 => const AlertsScreen(),
        2 => const FamilyScreen(),
        _ => _HomeSettingsTab(
            onSignOut: () async {
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.go('/login');
            },
          ),
      },
      bottomNavigationBar: _P07BottomNavigationBar(
        currentIndex: _tabIndex,
        alertsBadgeCount: badgeCount,
        onTap: (index) => setState(() {
          if (index != _tabIndex) _resolvedTimeRequests.clear();
          _tabIndex = index;
        }),
      ),
    );
  }

  PreferredSizeWidget _buildHomeAppBar(BuildContext context) {
    final l10n = context.l10n;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final toolbarHeight = scale > 1.35 ? kToolbarHeight * 1.35 : kToolbarHeight;
    return AppBar(
      toolbarHeight: toolbarHeight,
      title: Text(l10n.appName),
      actions: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: AppSpace.sm),
          child: TextButton.icon(
            key: const ValueKey('homeAddChildButton'),
            style: TextButton.styleFrom(
              minimumSize: const Size(kMinInteractiveDimension, 48),
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: AppSpace.sm,
              ),
            ),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AddChildDialog(),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.addChild),
          ),
        ),
      ],
    );
  }

  Widget _buildHomeBody(BuildContext context) {
    final l10n = context.l10n;
    final family = ref.watch(familyProvider);
    return family.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetryView(
        message: friendlyErrorText(l10n, e, () => l10n.familyLoadFailed),
        onRetry: () => ref.invalidate(familyProvider),
      ),
      data: (overview) {
        final selectedExists = _selectedChildId != null &&
            overview.children.any((c) => c.id == _selectedChildId);
        final activeFilter = selectedExists ? _selectedChildId : null;
        final visibleChildren = activeFilter == null
            ? overview.children
            : overview.children.where((c) => c.id == activeFilter).toList();

        return RefreshIndicator(
          onRefresh: () async {
            setState(_resolvedTimeRequests.clear);
            ref.invalidate(familyProvider);
            ref.invalidate(mfaResetPendingProvider);
            ref.invalidate(unacknowledgedAlertsProvider);
            ref.invalidate(unacknowledgedCountProvider);
            final session = ref.read(activePairingSessionProvider);
            if (session != null) {
              ref.invalidate(activePairingClaimProvider(session.code));
            }
          },
          child: ListView(
            key: const ValueKey('p07HomeList'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.xl,
            ),
            children: [
              if (overview.children.isNotEmpty) ...[
                _ChildFilterChipsRow(
                  children: overview.children,
                  selectedChildId: activeFilter,
                  onSelect: (id) => setState(() => _selectedChildId = id),
                ),
                const SizedBox(height: AppSpace.md),
              ],
              _NeedsYouSection(
                overview: overview,
                selectedChildId: activeFilter,
                resolvedTimeRequests: _resolvedTimeRequests,
                onTimeRequestResolved: (updated) {
                  if (!mounted) return;
                  setState(() => _resolvedTimeRequests[updated.id] = updated);
                },
              ),
              if (overview.children.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xxl * 2),
                  child: Center(child: Text(l10n.noChildrenYet)),
                )
              else
                for (var i = 0; i < visibleChildren.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpace.md),
                  HomeP07ChildCard(
                    key: ValueKey('homeChildCard-${visibleChildren[i].id}'),
                    child: visibleChildren[i],
                    overview: overview,
                  ),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _ChildFilterChipsRow extends StatelessWidget {
  final List<Child> children;
  final String? selectedChildId;
  final ValueChanged<String?> onSelect;

  const _ChildFilterChipsRow({
    required this.children,
    required this.selectedChildId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Wrap(
      key: const ValueKey('homeChildFilterChips'),
      spacing: AppSpace.sm,
      runSpacing: AppSpace.xs,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: ChoiceChip(
            key: const ValueKey('homeFilterChip-all'),
            label: Text(l10n.homeFilterAll),
            selected: selectedChildId == null,
            onSelected: (_) => onSelect(null),
          ),
        ),
        for (final child in children)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: ChoiceChip(
              key: ValueKey('homeFilterChip-${child.id}'),
              avatar: CircleAvatar(
                radius: 12,
                child: Text(
                  child.initials,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              label: Text(firstStrongIsolate(child.displayName)),
              selected: selectedChildId == child.id,
              onSelected: (_) => onSelect(child.id),
            ),
          ),
      ],
    );
  }
}

bool _isRequestAlert(Alert a) =>
    a.category == 'install_request' || isParentDecisionAlert(a);

class _NeedsYouSection extends ConsumerWidget {
  final FamilyOverview overview;
  final String? selectedChildId;
  final Map<String, Alert> resolvedTimeRequests;
  final ValueChanged<Alert> onTimeRequestResolved;

  const _NeedsYouSection({
    required this.overview,
    required this.selectedChildId,
    required this.resolvedTimeRequests,
    required this.onTimeRequestResolved,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final now = ref.watch(clockProvider)();

    final pendingResets = selectedChildId == null
        ? (ref.watch(mfaResetPendingProvider).valueOrNull ??
            const <MfaResetPendingRequest>[])
        : const <MfaResetPendingRequest>[];

    final pairSession = ref.watch(activePairingSessionProvider);
    final showPairClaimForFilter = pairSession != null &&
        !pairSession.isExpiredAt(now) &&
        (selectedChildId == null || pairSession.childId == selectedChildId);
    final pairClaim = showPairClaimForFilter
        ? ref.watch(activePairingClaimProvider(pairSession.code)).valueOrNull
        : null;
    final hasPendingPairClaim =
        pairClaim != null && pairClaim['status'] == 'pending';

    final finishSetupWidget = _buildFinishSetupBanner(context, ref);

    final unacked = ref.watch(unacknowledgedAlertsProvider).valueOrNull?.items ??
        const <Alert>[];
    final filteredUnacked = [
      for (final a in unacked)
        if (!a.acknowledged &&
            (selectedChildId == null || a.childId == selectedChildId))
          a,
    ];
    final seenRequestIds = <String>{};
    final requestAlerts = <Alert>[
      for (final a in filteredUnacked)
        if (_isRequestAlert(a) && seenRequestIds.add(a.id))
          resolvedTimeRequests[a.id] ?? a,
      for (final resolved in resolvedTimeRequests.values)
        if ((selectedChildId == null || resolved.childId == selectedChildId) &&
            seenRequestIds.add(resolved.id))
          resolved,
    ];
    final safetyAlerts = [
      for (final a in filteredUnacked)
        if (!_isRequestAlert(a) &&
            (a.severity == 'critical' || a.severity == 'warning'))
          a,
    ];

    final cards = <Widget>[
      if (pendingResets.isNotEmpty)
        _buildMfaResetBanner(context, pendingResets),
      if (pairSession != null && hasPendingPairClaim)
        _HomePairingClaimCard(session: pairSession, claim: pairClaim),
      if (finishSetupWidget != null) finishSetupWidget,
      for (final req in requestAlerts)
        _HomeChildRequestCard(
          key: ValueKey('homeRequestCard-${req.id}'),
          alert: req,
          overview: overview,
          onTimeRequestResolved: onTimeRequestResolved,
        ),
      if (safetyAlerts.isNotEmpty)
        _HomeSafetyAlertsCard(
          alerts: safetyAlerts,
          overview: overview,
          now: now,
        ),
    ];

    if (cards.isEmpty) return const SizedBox.shrink();

    return Padding(
      key: const ValueKey('homeNeedsYouSection'),
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.homeNeedsYou,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpace.sm),
            cards[i],
          ],
        ],
      ),
    );
  }

  Widget _buildMfaResetBanner(
    BuildContext context,
    List<MfaResetPendingRequest> requests,
  ) {
    final l10n = context.l10n;
    final first = requests.first;
    final name = first.requesterName.trim().isEmpty
        ? l10n.mfaResetRoleFamilyMember
        : firstStrongIsolate(first.requesterName.trim());
    final role = mfaResetRoleName(l10n, first.requesterRole);
    void openApproval() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MfaResetApprovalScreen(
            requestId: first.requestId,
            requesterName: first.requesterName,
            requesterRole: first.requesterRole,
            pendingState: first.state,
            pendingWindowEndsAt: first.windowEndsAt,
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          key: const ValueKey('mfaResetPendingBanner'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_reset, size: 20),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.mfaResetPendingBanner(
                          name,
                          role.isEmpty ? l10n.mfaResetRoleFamilyMember : role,
                        ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (requests.length > 1) ...[
                        const SizedBox(height: AppSpace.xxs),
                        Text(
                          l10n.mfaResetPendingMore(requests.length - 1),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                key: const ValueKey('mfaResetPendingReview'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(kMinInteractiveDimension, 48),
                ),
                onPressed: openApproval,
                child: Text(l10n.mfaResetPendingReview),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _buildFinishSetupBanner(BuildContext context, WidgetRef ref) {
    final onboarding = ref.watch(onboardingProvider);
    final childId = onboarding.childId;
    if (!onboarding.pairingPending || childId == null) return null;
    if (selectedChildId != null && selectedChildId != childId) return null;
    final child = overview.children.where((c) => c.id == childId).firstOrNull;
    if (child == null) return null;
    if (overview.devicesFor(child.id).isNotEmpty) return null;

    final l10n = context.l10n;
    return Card(
      key: const ValueKey('finishSetupBanner'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.onboardingFinishSetupTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              l10n.onboardingFinishSetupBody(
                firstStrongIsolate(child.displayName),
              ),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                key: const ValueKey('finishSetupPairNow'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(kMinInteractiveDimension, 48),
                ),
                onPressed: () async {
                  await context.push('/child/${child.id}/pair');
                  if (!context.mounted) return;
                  ref.invalidate(familyProvider);
                  try {
                    final refreshed = await ref.read(familyProvider.future);
                    if (refreshed.devicesFor(child.id).isNotEmpty) {
                      await ref
                          .read(onboardingProvider.notifier)
                          .clearPairingPending();
                    }
                  } catch (_) {}
                },
                child: Text(l10n.onboardingPairNow),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class _HomePairingClaimCard extends ConsumerStatefulWidget {
  final ActivePairingSession session;
  final Map<String, dynamic> claim;

  const _HomePairingClaimCard({
    required this.session,
    required this.claim,
  });

  @override
  ConsumerState<_HomePairingClaimCard> createState() =>
      _HomePairingClaimCardState();
}

class _HomePairingClaimCardState extends ConsumerState<_HomePairingClaimCard> {
  bool _deciding = false;
  bool _failed = false;

  Future<void> _decide(bool allow) async {
    final claimId = widget.claim['claimId']?.toString();
    if (claimId == null || claimId.isEmpty || _deciding) return;
    setState(() {
      _deciding = true;
      _failed = false;
    });
    try {
      await ref.read(apiClientProvider).raw.post(
            '/v1/devices/pair/claims/$claimId/${allow ? 'approve' : 'deny'}',
          );
      if (!mounted) return;
      ref.read(activePairingSessionProvider.notifier).state = null;
      ref.invalidate(familyProvider);
    } catch (_) {
      if (mounted) {
        setState(() {
          _deciding = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final deviceLabel = ltrIsolate(pairClaimDeviceLabel(widget.claim));
    return Card(
      key: const ValueKey('homePairingClaimBanner'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.pairClaimTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              l10n.pairClaimBody(deviceLabel),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (widget.claim['dataCleared'] == true) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.pairClaimDataCleared,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: tokens.danger),
              ),
            ],
            if (_failed) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.pairClaimError,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: tokens.danger),
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                OutlinedButton(
                  key: const ValueKey('homePairClaimDeny'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(kMinInteractiveDimension, 48),
                  ),
                  onPressed: _deciding ? null : () => _decide(false),
                  child: Text(l10n.pairClaimDeny),
                ),
                FilledButton(
                  key: const ValueKey('homePairClaimAllow'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(kMinInteractiveDimension, 48),
                  ),
                  onPressed: _deciding ? null : () => _decide(true),
                  child: Text(l10n.allowAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeChildRequestCard extends ConsumerStatefulWidget {
  final Alert alert;
  final FamilyOverview overview;
  final ValueChanged<Alert>? onTimeRequestResolved;

  const _HomeChildRequestCard({
    super.key,
    required this.alert,
    required this.overview,
    this.onTimeRequestResolved,
  });

  @override
  ConsumerState<_HomeChildRequestCard> createState() =>
      _HomeChildRequestCardState();
}

class _HomeChildRequestCardState extends ConsumerState<_HomeChildRequestCard> {
  bool _busy = false;

  bool get _isTimeRequest => widget.alert.requestedScreenTimeMinutes != null;

  int get _requestedMinutes => widget.alert.requestedScreenTimeMinutes ?? 15;

  String get _packageId =>
      widget.alert.metadata['packageId']?.toString().trim() ?? '';

  String get _appLabel {
    final appName = widget.alert.metadata['appName']?.toString().trim() ?? '';
    if (appName.isNotEmpty) return appName;
    if (_packageId.isNotEmpty) return _packageId;
    return widget.alert.title;
  }

  Future<void> _ackOnly() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(apiClientProvider)
          .raw
          .post('/v1/alerts/${widget.alert.id}/ack');
      ref.read(alertsSeenProvider.notifier).markAcknowledged(widget.alert.id);
      ref.invalidate(unacknowledgedAlertsProvider);
      ref.invalidate(unacknowledgedCountProvider);
      ref.invalidate(alertsProvider);
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(context.l10n, e, () => context.l10n.acknowledgeFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }


  Future<void> _allowAppAndAck() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (_packageId.isEmpty) {
      await _ackOnly();
      return;
    }
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider).raw;
      final res = await api.get('/v1/rules/${widget.alert.childId}');
      final saved = RuleSet.fromJson(Map<String, dynamic>.from(res.data as Map));
      final updatedRules = [...saved.appRules];
      final nextRule = AppRule(
        packageId: _packageId,
        appName: _appLabel,
        action: 'allow',
      );
      final existingIdx =
          updatedRules.indexWhere((r) => r.packageId == _packageId);
      if (existingIdx == -1) {
        updatedRules.add(nextRule);
      } else {
        updatedRules[existingIdx] = nextRule;
      }
      final submitted = saved.copyWith(appRules: updatedRules);
      await api.patch(
        '/v1/rules/${widget.alert.childId}',
        data: submitted.changesFrom(saved),
      );
      await api.post('/v1/alerts/${widget.alert.id}/ack');
      ref.read(alertsSeenProvider.notifier).markAcknowledged(widget.alert.id);
      ref.invalidate(rulesProvider(widget.alert.childId));
      ref.invalidate(familyProvider);
      ref.invalidate(unacknowledgedAlertsProvider);
      ref.invalidate(unacknowledgedCountProvider);
      ref.invalidate(alertsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.appAllowedSnack(ltrIsolate(_appLabel)))),
        );
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.blockFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final child = widget.overview.children
        .where((c) => c.id == widget.alert.childId)
        .firstOrNull;
    final childName = firstStrongIsolate(
      child?.displayName.trim().isNotEmpty == true
          ? child!.displayName.trim()
          : l10n.childFallback,
    );
    final devices = widget.overview.devicesFor(widget.alert.childId);
    final iosOnly = devices.isNotEmpty &&
        devices.every((d) => d.platform.toLowerCase() == 'ios');

    final title = _isTimeRequest
        ? l10n.timeRequestTitle(childName, _requestedMinutes)
        : l10n.homeAccessRequestTitle(childName, ltrIsolate(_appLabel));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpace.sm),
            if (_isTimeRequest)
              iosOnly
                  ? Text(
                      l10n.homeNotYetOnIphone,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.tokens.onSurfaceVariant),
                    )
                  : TimeRequestActions(
                      key: ValueKey('homeTimeRequestActions-${widget.alert.id}'),
                      alert: widget.alert,
                      onResolved: widget.onTimeRequestResolved,
                    )
            else
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  FilledButton(
                    key: ValueKey('homeReqAllow-${widget.alert.id}'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(kMinInteractiveDimension, 48),
                    ),
                    onPressed: _busy ? null : _allowAppAndAck,
                    child: Text(l10n.allowAction),
                  ),
                  OutlinedButton(
                    key: ValueKey('homeReqKeepBlocked-${widget.alert.id}'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(kMinInteractiveDimension, 48),
                    ),
                    onPressed: _busy ? null : _ackOnly,
                    child: Text(l10n.homeKeepBlocked),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeSafetyAlertsCard extends StatelessWidget {
  final List<Alert> alerts;
  final FamilyOverview overview;
  final DateTime now;

  const _HomeSafetyAlertsCard({
    required this.alerts,
    required this.overview,
    required this.now,
  });

  String _categoryLabel(AppLocalizations l10n, String category) =>
      switch (category) {
        'sos' => l10n.alertCategorySos,
        'tamper' => l10n.alertCategoryTamper,
        'social_concern' => l10n.alertCategorySocialConcern,
        'gaming_chat' => l10n.alertCategoryGamingChat,
        'cyberbullying' => l10n.alertCategoryCyberbullying,
        'self_harm' => l10n.alertCategorySelfHarm,
        'grooming' => l10n.alertCategoryGrooming,
        'web_threat' => l10n.alertCategoryWebThreat,
        'vpn_detected' => l10n.alertCategoryVpnDetected,
        'geofence' => l10n.alertCategoryGeofence,
        'device_restarted' => l10n.alertCategoryDeviceRestarted,
        _ => l10n.alertCategoryAiConcern,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final newest = alerts.first;
    final child =
        overview.children.where((c) => c.id == newest.childId).firstOrNull;
    final childName = firstStrongIsolate(
      child?.displayName.trim().isNotEmpty == true
          ? child!.displayName.trim()
          : l10n.childFallback,
    );
    final hasCritical = alerts.any((a) => a.severity == 'critical');
    final accent =
        hasCritical ? tokens.severityCriticalText : tokens.severityWarningText;
    final dotColor =
        hasCritical ? tokens.severityCritical : tokens.severityWarning;

    final ts = newest.effectiveTimestamp ?? newest.createdAt;
    final ageStr = ts == null
        ? null
        : _formatRelativeAgo(l10n, now.difference(ts.toLocal()));
    final subtitleParts = <String>[
      childName,
      _categoryLabel(l10n, newest.category),
      if (ageStr != null) ageStr,
    ];

    return Card(
      key: const ValueKey('homeSafetyAlertsCard'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: dotColor.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.warning_amber_rounded,
                      size: 20, color: accent),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.homeSafetyAlertsToReview(alerts.length),
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(color: accent),
                      ),
                      const SizedBox(height: AppSpace.xxs),
                      Text(
                        subtitleParts.join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                key: const ValueKey('homeSafetyAlertsReviewButton'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(kMinInteractiveDimension, 48),
                ),
                onPressed: () {
                  if (alerts.length == 1) {
                    context.push('/alerts/${newest.id}', extra: newest);
                  } else {
                    context.push('/alerts');
                  }
                },
                child: Text(l10n.mfaResetPendingReview),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class HomeP07ChildCard extends ConsumerStatefulWidget {
  final Child child;
  final FamilyOverview overview;

  const HomeP07ChildCard({
    super.key,
    required this.child,
    required this.overview,
  });

  @override
  ConsumerState<HomeP07ChildCard> createState() => _HomeP07ChildCardState();
}

class _HomeP07ChildCardState extends ConsumerState<HomeP07ChildCard> {
  Timer? _bonusHoldTimer;
  int? _pendingBonusMinutes;
  bool _grantingBonus = false;
  bool _bonusSentWaitingAck = false;
  bool _busyInternet = false;
  bool _busyLock = false;
  bool? _optimisticLocked;

  @override
  void dispose() {
    _bonusHoldTimer?.cancel();
    super.dispose();
  }

  void _cancelPendingBonus() {
    _bonusHoldTimer?.cancel();
    _bonusHoldTimer = null;
    if (mounted) {
      setState(() => _pendingBonusMinutes = null);
    }
  }

  void _scheduleBonusGrant(int minutes) {
    if (_pendingBonusMinutes != null || _grantingBonus) return;
    final l10n = context.l10n;
    final hold = ref.read(p07BonusHoldDurationProvider);
    setState(() {
      _pendingBonusMinutes = minutes;
      _bonusSentWaitingAck = false;
    });

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: hold > Duration.zero ? hold : const Duration(seconds: 4),
          content: Text(
            l10n.homeSendingBonusSnack(formatHomeDuration(l10n, minutes, genitive: true)),
          ),
          action: SnackBarAction(
            label: l10n.undo,
            onPressed: _cancelPendingBonus,
          ),
        ),
      );

    if (hold <= Duration.zero) {
      unawaited(_executeBonusGrant(minutes));
    } else {
      _bonusHoldTimer = Timer(hold, () {
        if (!mounted || _pendingBonusMinutes != minutes) return;
        unawaited(_executeBonusGrant(minutes));
      });
    }
  }

  Future<void> _executeBonusGrant(int minutes) async {
    final l10n = context.l10n;
    setState(() {
      _pendingBonusMinutes = null;
      _grantingBonus = true;
    });
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/${widget.child.id}/bonus',
        data: {'minutes': minutes},
      );
      ref.invalidate(rulesProvider(widget.child.id));
      ref.invalidate(familyProvider);
      for (final d in widget.overview.devicesFor(widget.child.id)) {
        ref.invalidate(deviceCommandHistoryProvider(d.id));
      }
      if (mounted) {
        setState(() => _bonusSentWaitingAck = true);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(l10n.bonusGranted(minutes))),
          );
      }
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.bonusFailed),
        );
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.bonusFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _grantingBonus = false);
    }
  }

  Future<void> _toggleChildInternet(bool currentlyPaused) async {
    if (_busyInternet) return;
    final l10n = context.l10n;
    setState(() => _busyInternet = true);
    try {
      if (currentlyPaused) {
        await resumeInternet(ref, widget.child.id);
      } else {
        await pauseInternet(ref, widget.child.id);
      }
      for (final d in widget.overview.devicesFor(widget.child.id)) {
        ref.invalidate(deviceCommandHistoryProvider(d.id));
      }
      if (mounted) {
        final nextLabel = currentlyPaused
            ? l10n.homeResumeInternet
            : l10n.homePauseInternet;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('$nextLabel · ${l10n.homeSentToPhone}'),
              action: SnackBarAction(
                label: l10n.undo,
                onPressed: () => unawaited(_toggleChildInternet(!currentlyPaused)),
              ),
            ),
          );
      }
    } on ControlsRefusal catch (r) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, r.error, () => l10n.internetChangeFailed),
        );
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.internetChangeFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _busyInternet = false);
    }
  }

  Future<void> _toggleChildLock(
    List<Device> lockableDevices,
    bool currentlyLocked,
  ) async {
    if (_busyLock || lockableDevices.isEmpty) return;
    final l10n = context.l10n;
    final command = currentlyLocked ? 'unlock' : 'lock';
    setState(() {
      _busyLock = true;
      _optimisticLocked = !currentlyLocked;
    });
    try {
      final api = ref.read(apiClientProvider).raw;
      for (final d in lockableDevices) {
        await api.post(
          '/v1/devices/${d.id}/command',
          data: {'command': command},
        );
        ref.invalidate(deviceCommandHistoryProvider(d.id));
      }
      if (mounted) {
        final actionText = currentlyLocked
            ? l10n.homeUnlockAllDevices
            : l10n.homeLockAllDevices;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('$actionText · ${l10n.homeSentToPhone}'),
              action: SnackBarAction(
                label: l10n.undo,
                onPressed: () =>
                    unawaited(_toggleChildLock(lockableDevices, !currentlyLocked)),
              ),
            ),
          );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _optimisticLocked = null);
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.commandFailed),
        );
      }
    } finally {
      if (mounted) setState(() => _busyLock = false);
    }
  }

  bool _isDeviceAckedLocked(List<DeviceCommand> history) {
    DeviceCommand? newestAcked;
    for (final c in history) {
      if (c.type != 'lock' && c.type != 'unlock') continue;
      if (c.status != 'acked') continue;
      final after = newestAcked?.createdAt;
      if (newestAcked == null ||
          after == null ||
          (c.createdAt?.isAfter(after) ?? false)) {
        newestAcked = c;
      }
    }
    return newestAcked?.type == 'lock';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider)();
    final child = widget.child;
    final devices = widget.overview.devicesFor(child.id);
    final nonIosDevices = [
      for (final d in devices)
        if (d.platform.toLowerCase() != 'ios') d,
    ];
    final iosOnly = devices.isNotEmpty && nonIosDevices.isEmpty;
    // #1089: an iPhone joins Lock / Pause internet only once its own report says `ready`.
    final lockableDevices = [
      for (final d in devices)
        if (deviceRunsControl(d, 'lock_screen')) d,
    ];
    final iosLockReady = iosOnly && lockableDevices.isNotEmpty;
    final iosInternetReady =
        iosOnly && devices.any((d) => deviceRunsControl(d, 'pause_internet'));
    final primaryDevice = nonIosDevices.firstOrNull ?? devices.firstOrNull;
    final primaryHistory = primaryDevice != null
        ? (ref.watch(deviceCommandHistoryProvider(primaryDevice.id)).valueOrNull ??
            const <DeviceCommand>[])
        : const <DeviceCommand>[];

    final internetPaused =
        ref.watch(internetPausedProvider(child.id)).valueOrNull ?? false;
    final rules = ref.watch(rulesProvider(child.id)).valueOrNull;
    final locationValue = ref.watch(locationProvider(child.id));
    final location = locationValue.valueOrNull;
    final locationRefused = locationValue.hasError &&
        ReadPermissionRequired.isRefusal(locationValue.error!);

    final derivedLocked = lockableDevices.isNotEmpty &&
        lockableDevices.every((d) {
          final h = ref.watch(deviceCommandHistoryProvider(d.id)).valueOrNull ??
              const <DeviceCommand>[];
          return _isDeviceAckedLocked(h);
        });
    final isLocked = _optimisticLocked ?? derivedLocked;

    final stateLabel = resolveHomeChildStateLabel(
      l10n: l10n,
      pausedOrLocked: internetPaused || isLocked,
      rules: rules,
      now: now,
      utcOffsetMinutes: widget.overview.family.utcOffsetMinutes,
    );

    final timeSummary = computeHomeTimeSummary(
      usedMinutes: child.screenTimeTodayMinutes,
      rules: rules,
      now: now,
      utcOffsetMinutes: widget.overview.family.utcOffsetMinutes,
      primaryDeviceHistory: primaryHistory,
    );

    final offlineDevices = [for (final d in devices) if (!d.isOnline) d];
    final seenLine = _buildSeenAndBatteryLine(l10n, primaryDevice, now);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: ValueKey('homeChildHeader-${child.id}'),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: () => context.push('/child/${child.id}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: tokens.primaryContainer,
                      foregroundColor: tokens.onPrimaryContainer,
                      child: Text(child.initials),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            firstStrongIsolate(child.displayName),
                            style: text.titleMedium,
                          ),
                          const SizedBox(height: AppSpace.xxs),
                          Text(
                            stateLabel,
                            key: ValueKey('homeChildState-${child.id}'),
                            style: text.labelMedium?.copyWith(
                              color: (internetPaused || isLocked)
                                  ? tokens.warn
                                  : tokens.onSurfaceVariant,
                            ),
                          ),
                          if (seenLine != null) ...[
                            const SizedBox(height: AppSpace.xxs),
                            Text(
                              seenLine,
                              style: text.bodySmall?.copyWith(
                                color: tokens.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
              ),
            ),
            if (offlineDevices.isNotEmpty) ...[
              const SizedBox(height: AppSpace.sm),
              for (final d in offlineDevices)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.xxs),
                  child: _OfflineDevicePill(device: d, now: now),
                ),
            ],
            const SizedBox(height: AppSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.location_on_outlined,
                  size: 16,
                  color: tokens.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: locationRefused || location == null
                      ? Text(
                          locationRefused
                              ? l10n.readPermissionRequired
                              : l10n.noLocationYet,
                          style: text.bodySmall,
                        )
                      : PlaceSummaryLine(
                          ping: location,
                          style: text.bodySmall,
                          onTap: () =>
                              context.push('/child/${child.id}?tab=location'),
                        ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            if (iosOnly && child.screenTimeTodayMinutes == 0)
              Text(
                l10n.homeNotYetOnIphone,
                key: ValueKey('homeIosTimeNotYet-${child.id}'),
                style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              )
            else
              _HomeTimeLeftBlock(
                childId: child.id,
                summary: timeSummary,
              ),
            if (_bonusSentWaitingAck) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.homeSentToPhone,
                key: ValueKey('homeSentToPhone-${child.id}'),
                style: text.labelSmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            // U104: bonus +15/+30 is never live on an iPhone yet, so a faded button always remains and the
            // banner stays as its visible reason even when Lock or Pause internet is ready.
            if (iosOnly) ...[
              Container(
                key: ValueKey('homeIosControlsNotYet-${child.id}'),
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: AppSpace.sm,
                  vertical: AppSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: tokens.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: tokens.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: tokens.onSurfaceVariant),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        l10n.homeNotYetOnIphone,
                        style: text.bodySmall?.copyWith(
                          color: tokens.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.xs),
            ],
            _ChildActionGroup(
              childId: child.id,
              iosOnly: iosOnly,
              iosLockReady: iosLockReady,
              iosInternetReady: iosInternetReady,
              hasDevices: lockableDevices.isNotEmpty,
              bonusBusy: _pendingBonusMinutes != null || _grantingBonus,
              internetBusy: _busyInternet,
              internetPaused: internetPaused,
              lockBusy: _busyLock,
              isLocked: isLocked,
              onPlus15: () => _scheduleBonusGrant(15),
              onPlus30: () => _scheduleBonusGrant(30),
              onToggleInternet: () => _toggleChildInternet(internetPaused),
              onToggleLock: () => _toggleChildLock(lockableDevices, isLocked),
              onIosNotYetTap: () {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(content: Text(l10n.homeNotYetOnIphone)),
                  );
              },
            ),
            // #1275: an iPhone Lock or Pause lifts by itself after 24 hours (force-quit safety net); UI/UX
            // 7223625900: one bodySmall line under the row, only while one of them is live.
            if (iosLockReady || iosInternetReady) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.homeIosAutoLiftNote,
                key: ValueKey('homeIosAutoLiftNote-${child.id}'),
                style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _buildSeenAndBatteryLine(
    AppLocalizations l10n,
    Device? device,
    DateTime now,
  ) {
    if (device == null) return null;
    final parts = <String>[];
    if (device.lastSeen != null) {
      final age = now.difference(device.lastSeen!.toLocal());
      if (age.inMinutes < 1) {
        parts.add(l10n.homeSeenJustNow);
      } else {
        parts.add(l10n.homeSeenAgo(formatHomeElapsed(l10n, age, genitive: true)));
      }
    }
    if (device.batteryPct > 0) {
      parts.add(l10n.homeBatteryPct(ltrIsolate('${device.batteryPct}%')));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
class _OfflineDevicePill extends StatelessWidget {
  final Device device;
  final DateTime now;

  const _OfflineDevicePill({required this.device, required this.now});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final ageText = device.lastSeen == null
        ? l10n.statusOffline
        : l10n.homeOfflineFor(
            formatHomeElapsed(l10n, now.difference(device.lastSeen!.toLocal()), genitive: true),
          );
    final label = device.model.trim().isEmpty
        ? ageText
        : '${ltrIsolate(device.model.trim())} · $ageText';

    return Container(
      key: ValueKey('homeOfflinePill-${device.id}'),
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: tokens.severityWarning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: tokens.warn),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 16, color: tokens.warn),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: tokens.warn),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeTimeLeftBlock extends StatelessWidget {
  final String childId;
  final HomeTimeSummary summary;

  const _HomeTimeLeftBlock({
    required this.childId,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;

    if (summary.effectiveLimitMinutes <= 0) {
      return Text(
        formatHomeDuration(l10n, summary.usedMinutes),
        key: ValueKey('homeTimeUsedOnly-$childId'),
        style: text.bodyMedium,
      );
    }

    final leftStr = l10n.homeTimeLeft(
      formatHomeDuration(l10n, summary.remainingMinutes),
    );
    final ofLimitStr = l10n.homeOfLimit(
      formatHomeDuration(l10n, summary.effectiveLimitMinutes, genitive: true),
    );
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final width = MediaQuery.sizeOf(context).width;
    final stackVertically = scale > 1.35 || width < 350;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stackVertically) ...[
          Text(
            leftStr,
            key: ValueKey('homeTimeLeft-$childId'),
            style: text.titleSmall,
          ),
          const SizedBox(height: AppSpace.xxs),
          Text(
            ofLimitStr,
            style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ] else
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  leftStr,
                  key: ValueKey('homeTimeLeft-$childId'),
                  style: text.titleSmall,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Flexible(
                child: Text(
                  ofLimitStr,
                  textAlign: TextAlign.end,
                  style: text.bodySmall?.copyWith(
                    color: tokens.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpace.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: LinearProgressIndicator(
            key: ValueKey('homeTimeProgress-$childId'),
            value: summary.progress,
            minHeight: 8,
            color: tokens.primary,
            backgroundColor: tokens.surfaceContainer,
          ),
        ),
      ],
    );
  }
}

/// #1089: whether [device] can run the control behind [feature] (`lock_screen`, `pause_internet`).
///
/// Android always can. An iPhone can only once its own capability report says `ready`: the server keeps
/// answering `not_supported` from its table until the iOS build really shields (Screen Time), so the
/// buttons stay "Not yet available on iPhone" until then and never send a command the phone would refuse.
@visibleForTesting
bool deviceRunsControl(Device device, String feature) =>
    device.platform.toLowerCase() != 'ios' || device.setup?.feature(feature) == 'ready';

class _ChildActionGroup extends StatelessWidget {
  final String childId;
  final bool iosOnly;
  final bool iosLockReady;
  final bool iosInternetReady;
  final bool hasDevices;
  final bool bonusBusy;
  final bool internetBusy;
  final bool internetPaused;
  final bool lockBusy;
  final bool isLocked;
  final VoidCallback onPlus15;
  final VoidCallback onPlus30;
  final VoidCallback onToggleInternet;
  final VoidCallback onToggleLock;
  final VoidCallback onIosNotYetTap;

  const _ChildActionGroup({
    required this.childId,
    required this.iosOnly,
    this.iosLockReady = false,
    this.iosInternetReady = false,
    required this.hasDevices,
    required this.bonusBusy,
    required this.internetBusy,
    required this.internetPaused,
    required this.lockBusy,
    required this.isLocked,
    required this.onPlus15,
    required this.onPlus30,
    required this.onToggleInternet,
    required this.onToggleLock,
    required this.onIosNotYetTap,
  });

  Widget _actionButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool highlighted = false,
    bool iosReady = false,
  }) {
    final l10n = context.l10n;
    if (iosOnly && !iosReady) {
      final faded =
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45);
      return Semantics(
        button: true,
        label: '$label, ${l10n.homeNotYetOnIphone}',
        excludeSemantics: true,
        child: OutlinedButton.icon(
          key: key,
          onPressed: onIosNotYetTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(kMinInteractiveDimension, 48),
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.xs,
            ),
            foregroundColor: faded,
            side: BorderSide(color: context.tokens.border),
            alignment: AlignmentDirectional.centerStart,
          ),
          icon: Icon(icon, size: 18, color: faded),
          label: Text(label, softWrap: true),
        ),
      );
    }

    if (highlighted) {
      return FilledButton.icon(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(kMinInteractiveDimension, 48),
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpace.sm,
            vertical: AppSpace.xs,
          ),
          alignment: AlignmentDirectional.centerStart,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label, softWrap: true),
      );
    }

    return FilledButton.tonalIcon(
      key: key,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(kMinInteractiveDimension, 48),
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpace.sm,
          vertical: AppSpace.xs,
        ),
        alignment: AlignmentDirectional.centerStart,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, softWrap: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final buttons = <Widget>[
      _actionButton(
        context,
        key: ValueKey('homeActionPlus15-$childId'),
        icon: Icons.more_time,
        label: l10n.homeBonusPlus15,
        onPressed: bonusBusy ? null : onPlus15,
      ),
      _actionButton(
        context,
        key: ValueKey('homeActionPlus30-$childId'),
        icon: Icons.more_time,
        label: l10n.homeBonusPlus30,
        onPressed: bonusBusy ? null : onPlus30,
      ),
      _actionButton(
        context,
        key: ValueKey('homeActionPauseInternet-$childId'),
        icon: internetPaused ? Icons.wifi : Icons.wifi_off,
        label: internetPaused
            ? l10n.homeResumeInternet
            : l10n.homePauseInternet,
        onPressed: internetBusy ? null : onToggleInternet,
        highlighted: internetPaused,
        iosReady: iosInternetReady,
      ),
      _actionButton(
        context,
        key: ValueKey('homeActionLock-$childId'),
        icon: isLocked ? Icons.lock_open : Icons.lock_outline,
        label: isLocked
            ? l10n.homeUnlockAllDevices
            : l10n.homeLockAllDevices,
        onPressed: (!hasDevices || lockBusy) ? null : onToggleLock,
        highlighted: isLocked,
        iosReady: iosLockReady,
      ),
    ];

    return LayoutBuilder(
      key: ValueKey('homeActionGroup-$childId'),
      builder: (context, constraints) {
        final singleColumn = constraints.maxWidth < 290 || scale > 1.35;
        if (singleColumn) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpace.xs),
                buttons[i],
              ],
            ],
          );
        }
        return Column(
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(child: buttons[1]),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: buttons[2]),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(child: buttons[3]),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeSettingsTab extends ConsumerWidget {
  final VoidCallback onSignOut;

  const _HomeSettingsTab({required this.onSignOut});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // P-22 replaces exactly the four links it holds rows for. With the P-07 home there is no dashboard menu,
    // so without this the grouped Settings screen would be unreachable when both switches are on — the failure
    // the dashboard menu entry exists to prevent. Off by default, like P-22 itself.
    final p22 = ref.watch(p22SettingsEnabledProvider);
    final items = <(Key, IconData, String, VoidCallback)>[
      if (p22)
        (
          const ValueKey('homeSettingsP22'),
          Icons.settings_outlined,
          l10n.settingsTitle,
          () => context.push('/settings'),
        )
      else ...[
        (
          const ValueKey('homeSettingsAppearance'),
          Icons.palette_outlined,
          l10n.appearanceMenu,
          () => context.push('/settings/appearance'),
        ),
        (
          const ValueKey('homeSettingsDigests'),
          Icons.mail_outline,
          l10n.digestPreferencesMenu,
          () => context.push('/settings/digests'),
        ),
        (
          const ValueKey('homeSettingsMfa'),
          Icons.security_outlined,
          l10n.mfaMenu,
          () => context.push('/settings/mfa'),
        ),
        (
          const ValueKey('homeSettingsDeleteAccount'),
          Icons.delete_outline,
          l10n.deleteAccountTitle,
          () => context.push('/settings/delete-account'),
        ),
      ],
      // "Privacy and data" has no row in P-22's approved list and its only other way in is the dashboard menu,
      // which the P-07 home replaces. It therefore shows in **both** states: the 17:06 rule says a shipped,
      // signed entry does not drop out without an equivalent in its place (UI/UX Bureau, 17:29).
      (
        const ValueKey('homeSettingsPrivacy'),
        Icons.privacy_tip_outlined,
        l10n.privacyMenu,
        () => context.push('/settings/privacy'),
      ),
      (
        const ValueKey('homeSettingsSignOut'),
        Icons.logout,
        l10n.signOutTooltip,
        onSignOut,
      ),
    ];

    return ListView.separated(
      key: const ValueKey('homeSettingsList'),
      padding: const EdgeInsetsDirectional.all(AppSpace.lg),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpace.sm),
      itemBuilder: (context, index) {
        final (key, icon, label, onTap) = items[index];
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            key: key,
            minVerticalPadding: AppSpace.md,
            leading: Icon(icon),
            title: Text(label),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
        );
      },
    );
  }
}

class _P07BottomNavigationBar extends StatelessWidget {
  final int currentIndex;
  final int alertsBadgeCount;
  final ValueChanged<int> onTap;

  const _P07BottomNavigationBar({
    required this.currentIndex,
    required this.alertsBadgeCount,
    required this.onTap,
  });

  Widget _tabItem(
    BuildContext context, {
    required Key key,
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    int badgeCount = 0,
  }) {
    final tokens = context.tokens;
    final selected = currentIndex == index;
    final fg = selected ? tokens.onPrimaryContainer : tokens.onSurfaceVariant;
    final bg = selected ? tokens.primaryContainer : Colors.transparent;

    Widget iconWidget = Icon(selected ? selectedIcon : icon, size: 22, color: fg);
    if (badgeCount > 0) {
      // U86 (#650, UI/UX 7214846306): clamp the badge's text scale so the count
      // pill never obscures the bell icon at 200% text while keeping Material's
      // default top-end offset.
      iconWidget = MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Badge(
          key: const ValueKey('p07AlertsBadge'),
          isLabelVisible: true,
          largeSize: 16,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          textStyle: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w700),
          label: Text(ltrIsolate('$badgeCount')),
          child: iconWidget,
        ),
      );
    }

    final isCompact = MediaQuery.sizeOf(context).width < 340 ||
        MediaQuery.textScalerOf(context).scale(1.0) > 1.35;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: () => onTap(index),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: kMinInteractiveDimension,
            minHeight: kMinInteractiveDimension,
          ),
          child: Container(
            padding: EdgeInsetsDirectional.symmetric(
              horizontal: isCompact ? 2 : AppSpace.xs,
              vertical: AppSpace.xs,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                iconWidget,
                const SizedBox(height: 2),
                MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: MediaQuery.textScalerOf(context)
                        .clamp(maxScaleFactor: 1.25),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: fg,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;

    final tabs = <Widget>[
      _tabItem(
        context,
        key: const ValueKey('p07Tab-home'),
        index: 0,
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: l10n.homeTabHome,
      ),
      _tabItem(
        context,
        key: const ValueKey('p07Tab-alerts'),
        index: 1,
        icon: Icons.notifications_outlined,
        selectedIcon: Icons.notifications,
        label: l10n.tabAlerts,
        badgeCount: alertsBadgeCount,
      ),
      _tabItem(
        context,
        key: const ValueKey('p07Tab-family'),
        index: 2,
        icon: Icons.people_outline,
        selectedIcon: Icons.people,
        label: l10n.homeTabFamily,
      ),
      _tabItem(
        context,
        key: const ValueKey('p07Tab-settings'),
        index: 3,
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        label: l10n.homeTabSettings,
      ),
    ];

    return Material(
      key: const ValueKey('p07BottomNav'),
      color: tokens.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.border)),
          ),
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpace.xs,
            vertical: AppSpace.xs,
          ),
          // U86 (#650): always keep the bottom navigation bar on one compact row,
          // including at 320 px width and 200% text scale.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpace.xxs),
                  Expanded(child: tabs[i]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}