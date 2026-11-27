import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';
import '../../providers/social_provider.dart';
import '../../theme/app_tokens.dart';
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';
import '../social/social_screen.dart' show socialAppIcon, socialAppLabel;
import '../social/social_vote_controls.dart';
import 'alert_detail_screen.dart'
    show
        PreviewRetryCard,
        PreviewUnavailableCard,
        SocialPreviewAvailability,
        formatAlertLocalTime,
        resolveSocialPreviewAvailability,
        socialVoteEventId;

/// Build-time switch for UX Final Decisions P-15 Alert detail (#1179).
/// Defaults to `false` so legacy `_SocialAlertDetailBody` remains the fallback.
const bool kP15AlertDetailDefault = bool.fromEnvironment('OSRA_UX_P15', defaultValue: false);

/// Feature switch for P-15 Alert detail (#1179).
final p15AlertDetailEnabledProvider = Provider<bool>((ref) => kP15AlertDetailDefault);

/// P-15 Alert detail body (#1179, Fix 2, #1065, #1059):
/// - Flagged part + "Possible concern — automatic checks can be wrong."
/// - Sender (#1059) + iPhone "Not yet available" state (Fix 8).
/// - Calm guidance (`CoachCardSection`).
/// - 4 action tiles including "Help {child} block {contact}" (Fix 2; no Call as primary).
/// - Footer = #1065 "Was OSRA right to flag this?" Concerning / Not concerning
///   (no separate "Mark reviewed" button; no machine labels; no "encrypted on device" banner).
class AlertDetailP15Body extends ConsumerStatefulWidget {
  final Alert alert;
  final bool showAllAlertsButton;
  final DateTime Function()? nowProvider;

  const AlertDetailP15Body({
    super.key,
    required this.alert,
    required this.showAllAlertsButton,
    this.nowProvider,
  });

  @override
  ConsumerState<AlertDetailP15Body> createState() => _AlertDetailP15BodyState();
}

class _AlertDetailP15BodyState extends ConsumerState<AlertDetailP15Body> {
  final _coachKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(alertsSeenProvider.notifier).markAlertOpened(widget.alert);
      }
    });
  }

  List<String> _concernTypesOf(Alert a) {
    final raw = a.metadata['concernTypes'];
    if (raw is List) {
      return [for (final t in raw) '$t'.trim()].where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }

  Future<void> _showHelpBlockDialog(
    BuildContext context, {
    required String childDisplay,
    required String contactDisplay,
    required String appDisplay,
  }) async {
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(l10n.p15HelpChildBlockContact(childDisplay, contactDisplay)),
        content: Text(l10n.p15HelpBlockGuideBody(childDisplay, appDisplay, contactDisplay)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.dismiss),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final isEnglish = context.localeName.startsWith('en');

    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == alert.childId).firstOrNull;
    final childDevices = overview?.devicesFor(alert.childId) ?? const <Device>[];
    final isIphoneOnly =
        childDevices.isNotEmpty && childDevices.every((d) => d.platform.toLowerCase() == 'ios');
    final device = alert.deviceId != null
        ? overview?.devices.where((d) => d.id == alert.deviceId).firstOrNull
        : null;

    final childName = (child != null && child.displayName.isNotEmpty)
        ? firstStrongIsolate(child.displayName)
        : l10n.childFallback;
    final appKey = alert.metadata['app']?.toString().trim().toLowerCase() ?? '';
    final appLabel = appKey.isEmpty ? null : socialAppLabel(appKey, l10n);
    final appDisplay = appLabel != null ? ltrIsolate(appLabel) : l10n.tabSocial;
    final concernTypes = _concernTypesOf(alert);
    final title = alert.hasSocialCountSummary && appLabel != null
        ? l10n.socialAlertCountTitle(alert.socialMessageCount, ltrIsolate(appLabel))
        : l10n.alertTitleFor(
            alert.category,
            alert.title,
            isEnglish: isEnglish,
            tamperType: alert.metadata['type']?.toString(),
          );

    final contactName = alert.socialContactName;
    final contactDisplay =
        contactName != null ? firstStrongIsolate(contactName) : l10n.socialAlertUnknownContact;
    final senderLine = l10n.socialAlertFromContactOnly(contactDisplay);

    final latestAt = alert.effectiveTimestamp;
    final latestClock = latestAt == null
        ? ''
        : ltrIsolate(normalizeDigits(DateFormat('HH:mm', 'en').format(latestAt.toLocal())));
    final timeLine = alert.hasSocialCountSummary && latestClock.isNotEmpty
        ? l10n.socialAlertLatestAt(latestClock)
        : (alert.createdAt != null
            ? formatAlertLocalTime(
                alert.createdAt!,
                l10n: l10n,
                localeName: context.localeName,
                now: widget.nowProvider?.call(),
              )
            : null);

    final sevDot = tokens.severityDot(alert.severity);
    final primary = alert.metadata['primarySocialEventId'];
    final concernId = primary is String && primary.isNotEmpty ? primary : null;
    final eventsProvider = concernId == null
        ? socialEventsProvider(alert.childId)
        : socialConcernProvider((childId: alert.childId, eventId: concernId));
    final eventsAsync = ref.watch(eventsProvider);
    final availability =
        resolveSocialPreviewAvailability(alert, eventsAsync, exactConcernId: concernId);
    final latestSourceEventId = socialVoteEventId(alert);
    final coachCard = coachCardFor(alert.category, concernTypes);

    return ListView(
      key: const ValueKey('p15AlertDetailScroll'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        // 1. Header: title, child/device, app, sender (#1059), time.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(Icons.flag_rounded, color: sevDot, size: 24),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                title,
                key: const ValueKey('p15Title'),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: tokens.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              device != null && device.model.isNotEmpty
                  ? '$childName · ${ltrIsolate(device.model)}'
                  : childName,
              key: const ValueKey('p15ChildDevice'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: tokens.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (appLabel != null)
              Chip(
                key: const ValueKey('p15AppChip'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: Icon(socialAppIcon(appKey), size: 16),
                label: Text(ltrIsolate(appLabel)),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          senderLine,
          key: const ValueKey('p15Sender'),
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.onSurfaceVariant),
        ),
        if (timeLine != null) ...[
          const SizedBox(height: 2),
          Text(
            timeLine,
            key: const ValueKey('p15Time'),
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
        if (isIphoneOnly) ...[
          const SizedBox(height: AppSpace.md),
          Card(
            key: const ValueKey('p15IphoneNotYet'),
            color: tokens.surfaceContainer,
            child: ListTile(
              leading: Icon(Icons.info_outline, color: tokens.onSurfaceVariant),
              title: Text(
                l10n.p15IphoneNotYet,
                style: theme.textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpace.md),

        // 2. Flagged part + "Possible concern — automatic checks can be wrong."
        Card(
          key: const ValueKey('p15FlaggedCard'),
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
                if (appLabel != null) ...[
                  Text(
                    l10n.socialAlertFlaggedInApp(ltrIsolate(appLabel)),
                    style: theme.textTheme.bodyLarge?.copyWith(color: tokens.onSurface),
                  ),
                  const SizedBox(height: AppSpace.xs),
                ],
                Text(
                  l10n.p15CanBeWrong,
                  key: const ValueKey('p15CanBeWrong'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: tokens.onSurfaceVariant),
                ),
                if (!isIphoneOnly) ...[
                  if (availability == SocialPreviewAvailability.available) ...[
                    if (concernId == null) ...[
                      const SizedBox(height: AppSpace.sm),
                      const PreviewUnavailableCard(
                        availability: SocialPreviewAvailability.expired,
                      ),
                    ],
                    const SizedBox(height: AppSpace.md),
                    FilledButton.icon(
                      key: const ValueKey('p15OpenSocial'),
                      style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
                      onPressed: () => context.push(Uri(
                        path: '/child/${alert.childId}/social',
                        queryParameters: concernId == null ? null : {'concernId': concernId},
                      ).toString()),
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: Text(l10n.socialAlertOpenActivity),
                    ),
                  ] else if (availability == SocialPreviewAvailability.transientError) ...[
                    const SizedBox(height: AppSpace.md),
                    PreviewRetryCard(
                      message: friendlyErrorText(
                        l10n,
                        eventsAsync.error ?? Exception('preview_unavailable'),
                        // U91 (#650): the preview has its own failure line; borrowing the
                        // alerts-list string told the parent the wrong thing failed.
                        () => l10n.p15PreviewLoadFailed,
                      ),
                      onRetry: () => ref.invalidate(eventsProvider),
                    ),
                  ] else ...[
                    const SizedBox(height: AppSpace.md),
                    PreviewUnavailableCard(availability: availability),
                  ],
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),

        // 3. Calm guidance.
        Container(
          key: _coachKey,
          child: CoachCardSection(card: coachCard),
        ),
        const SizedBox(height: AppSpace.lg),

        // 4. Four calm action tiles (Fix 2: "Help {child} block {contact}", no Call as primary).
        Text(
          l10n.p15ActionsHeader,
          style: theme.textTheme.titleMedium?.copyWith(
            color: tokens.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        _ActionTile(
          tileKey: const ValueKey('p15Action-talk'),
          icon: Icons.chat_bubble_outline,
          title: l10n.p15TalkWithChild(childName),
          onTap: () {
            final ctx = _coachKey.currentContext;
            if (ctx != null) {
              Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250));
            }
          },
        ),
        const SizedBox(height: AppSpace.xs),
        _ActionTile(
          tileKey: const ValueKey('p15Action-helpBlock'),
          icon: Icons.person_off_outlined,
          title: l10n.p15HelpChildBlockContact(childName, contactDisplay),
          onTap: () => _showHelpBlockDialog(
            context,
            childDisplay: childName,
            contactDisplay: contactDisplay,
            appDisplay: appDisplay,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        _ActionTile(
          tileKey: const ValueKey('p15Action-limits'),
          icon: Icons.timer_outlined,
          title: l10n.p15AdjustLimits,
          onTap: () => context.push('/child/${alert.childId}/rules'),
        ),
        const SizedBox(height: AppSpace.xs),
        _ActionTile(
          tileKey: const ValueKey('p15Action-apps'),
          icon: Icons.apps_outlined,
          title: l10n.p15ReviewAppRules,
          onTap: () => context.push('/child/${alert.childId}/rules?tab=apps'),
        ),

        // 5. Footer = #1065 "Was OSRA right to flag this?" Concerning / Not concerning (no Mark reviewed).
        if (latestSourceEventId != null &&
            availability != SocialPreviewAvailability.noPermission &&
            availability != SocialPreviewAvailability.expired) ...[
          const SizedBox(height: AppSpace.lg),
          const Divider(),
          const SizedBox(height: AppSpace.sm),
          KeyedSubtree(
            key: const ValueKey('p15VoteFooter'),
            child: SocialVoteControls(eventId: latestSourceEventId),
          ),
        ],

        if (widget.showAllAlertsButton) ...[
          const SizedBox(height: AppSpace.lg),
          OutlinedButton(
            key: const ValueKey('p15AllAlerts'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
            onPressed: () => context.go('/alerts'),
            child: Text(l10n.socialAlertViewAll),
          ),
        ],
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final Key tileKey;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _ActionTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Card(
      key: tileKey,
      color: tokens.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: tokens.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
            child: Row(
              children: [
                Icon(icon, color: tokens.primary),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: tokens.onSurface,
                        ),
                  ),
                ),
                Icon(Icons.chevron_right, color: tokens.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
