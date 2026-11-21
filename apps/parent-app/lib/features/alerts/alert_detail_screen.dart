import 'package:dio/dio.dart';
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
import '../../widgets/error_retry_view.dart';
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';
import '../rules/rules_behind_banner.dart';
import '../social/social_screen.dart' show socialAppIcon, socialAppLabel;

/// Whether [category] uses the dedicated #972 full-screen social alert detail route.
bool isSocialAlertCategory(String category) =>
    category == 'social_concern' || category == 'gaming_chat';

/// Availability of the encrypted Social activity preview for a social alert.
enum SocialPreviewAvailability {
  /// Guardian is authorized and at least one matching event exists (or is still loading).
  available,

  /// Guardian account lacks the `social` permission (`403 permission_required`).
  noPermission,

  /// Vault query succeeded, but no matching encrypted preview is stored or it has expired.
  expired,
}

/// Formats an alert's local timestamp using the #889 / U45 calendar-day keys without seconds,
/// keeping Western digits in Arabic and falling back safely for unsupported `intl` locales.
String formatAlertLocalTime(
  DateTime at, {
  required AppLocalizations l10n,
  required String localeName,
  DateTime? now,
}) {
  final local = at.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final safeLocale = DateFormat.localeExists(localeName)
      ? localeName
      : (localeName.startsWith('ar') ? 'ar' : 'en');
  final hm = normalizeDigits(DateFormat.Hm(safeLocale).format(local));
  final today = DateTime(ref.year, ref.month, ref.day);
  final day = DateTime(local.year, local.month, local.day);
  final when = switch (today.difference(day).inDays) {
    0 => l10n.alertAtTime(hm),
    1 => l10n.alertYesterdayAtTime(hm),
    _ => l10n.alertOnDateAtTime(
        normalizeDigits(DateFormat.MMMd(safeLocale).format(local)),
        hm,
      ),
  };
  return l10n.alertDetailSent(when);
}

/// Classifies preview availability from the child's authorized [socialEventsProvider] state.
///
/// Message content is never rendered here — this only decides whether to offer the
/// "Open Social activity" CTA or an explicit unavailable-preview explanation.
SocialPreviewAvailability resolveSocialPreviewAvailability(
  Alert alert,
  AsyncValue<List<SocialConcernEvent>> eventsAsync,
) {
  return eventsAsync.when(
    loading: () => SocialPreviewAvailability.available,
    error: (err, _) {
      if (err is DioException) {
        final perm = ReadPermissionRequired.from(err);
        if (perm != null && perm.permission == 'social') {
          return SocialPreviewAvailability.noPermission;
        }
      }
      return SocialPreviewAvailability.expired;
    },
    data: (events) {
      if (events.isEmpty) return SocialPreviewAvailability.expired;
      final appKey = alert.metadata['app']?.toString().trim().toLowerCase() ?? '';
      if (appKey.isEmpty) return SocialPreviewAvailability.available;
      final hasAppMatch = events.any((e) => e.app.trim().toLowerCase() == appKey);
      return hasAppMatch
          ? SocialPreviewAvailability.available
          : SocialPreviewAvailability.expired;
    },
  );
}

/// #972: Full-screen alert detail route (`/alerts/:id`) with normal Back navigation and a
/// single scrollable body (primary action inside the scroll so 200% text size never overlaps).
class AlertDetailScreen extends ConsumerWidget {
  final String alertId;
  final Alert? initialAlert;
  final DateTime Function()? nowProvider;

  const AlertDetailScreen({
    super.key,
    required this.alertId,
    this.initialAlert,
    this.nowProvider,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final canPop = Navigator.of(context).canPop();
    final alertsAsync = initialAlert != null
        ? AsyncValue<List<Alert>>.data([initialAlert!])
        : ref.watch(alertsProvider(const AlertFilter())).whenData((page) => page.items);

    void openAllAlerts() {
      if (canPop) {
        Navigator.of(context).pop();
      } else {
        context.go('/alerts');
      }
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const BackButtonIcon(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: openAllAlerts,
        ),
        title: Text(l10n.alertsTitle),
      ),
      body: alertsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ErrorRetryView(
              message: friendlyErrorText(l10n, err, () => l10n.alertsLoadFailed),
              onRetry: () => ref.invalidate(alertsProvider(const AlertFilter())),
            ),
            const SizedBox(height: AppSpace.sm),
            OutlinedButton(
              onPressed: () => context.go('/alerts'),
              child: Text(l10n.socialAlertViewAll),
            ),
          ],
        ),
        data: (alerts) {
          final alert = alerts.where((a) => a.id == alertId).firstOrNull;
          if (alert == null) {
            return _AlertUnavailableView(onOpenAllAlerts: () => context.go('/alerts'));
          }
          return _SocialAlertDetailBody(
            alert: alert,
            showAllAlertsButton: !canPop,
            nowProvider: nowProvider,
          );
        },
      ),
    );
  }
}

class _AlertUnavailableView extends StatelessWidget {
  final VoidCallback onOpenAllAlerts;
  const _AlertUnavailableView({required this.onOpenAllAlerts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ListView(
      key: const ValueKey('alertDetailUnavailable'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.notifications_off_outlined,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        l10n.socialAlertUnavailableTitle,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Text(l10n.socialAlertUnavailableBody, style: theme.textTheme.bodyMedium),
                const SizedBox(height: AppSpace.md),
                FilledButton(
                  onPressed: onOpenAllAlerts,
                  child: Text(l10n.socialAlertViewAll),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SocialAlertDetailBody extends ConsumerWidget {
  final Alert alert;
  final bool showAllAlertsButton;
  final DateTime Function()? nowProvider;

  const _SocialAlertDetailBody({
    required this.alert,
    required this.showAllAlertsButton,
    this.nowProvider,
  });

  List<String> _concernTypesOf(Alert a) {
    final raw = a.metadata['concernTypes'];
    if (raw is List) return [for (final t in raw) '$t'.trim()].where((s) => s.isNotEmpty).toList();
    return const [];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final isEnglish = context.localeName.startsWith('en');

    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == alert.childId).firstOrNull;
    final device = alert.deviceId != null
        ? overview?.devices.where((d) => d.id == alert.deviceId).firstOrNull
        : null;

    final appKey = alert.metadata['app']?.toString().trim().toLowerCase() ?? '';
    final appLabel = appKey.isEmpty ? null : socialAppLabel(appKey, l10n);
    final concernTypes = _concernTypesOf(alert);
    final title = l10n.alertTitleFor(
      alert.category,
      alert.title,
      isEnglish: isEnglish,
      tamperType: alert.metadata['type']?.toString(),
    );

    final sevDot = tokens.severityDot(alert.severity);
    final sevText = tokens.severityText(alert.severity);

    final contextParts = <String>[
      if (child != null && child.displayName.isNotEmpty) child.displayName,
      if (device != null && device.model.isNotEmpty) ltrIsolate(device.model),
    ];

    final eventsAsync = ref.watch(socialEventsProvider(alert.childId));
    final availability = resolveSocialPreviewAvailability(alert, eventsAsync);
    final coachCard = coachCardFor(alert.category, concernTypes);

    return ListView(
      key: const ValueKey('alertDetailScroll'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        RulesBehindBanner(childId: alert.childId),
        // 1. Top context: title, affected app, concern, child/device, and local time.
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
                key: const ValueKey('alertDetailTitle'),
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        if (appLabel != null || concernTypes.isNotEmpty) ...[
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              if (appLabel != null)
                Chip(
                  key: const ValueKey('alertDetailAppChip'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  avatar: Icon(socialAppIcon(appKey), size: 16),
                  label: Text(ltrIsolate(appLabel)),
                ),
              for (final tag in concernTypes)
                Chip(
                  key: ValueKey('alertDetailConcern-$tag'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: sevDot.withValues(alpha: 0.14),
                  side: BorderSide(color: sevDot.withValues(alpha: 0.4)),
                  label: Text(
                    l10n.searchRiskCategory(tag),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: sevText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
        ],
        if (contextParts.isNotEmpty) ...[
          Text(
            contextParts.join(' · '),
            key: const ValueKey('alertDetailChildDevice'),
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpace.xs),
        ],
        if (alert.createdAt != null) ...[
          Text(
            formatAlertLocalTime(
              alert.createdAt!,
              l10n: l10n,
              localeName: context.localeName,
              now: nowProvider?.call(),
            ),
            key: const ValueKey('alertDetailTime'),
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.md),
        ],
        // 2. Short localized framing (never message content).
        if (appLabel != null) ...[
          Text(
            l10n.socialAlertFlaggedInApp(ltrIsolate(appLabel)),
            key: const ValueKey('alertDetailFraming'),
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        // 3. Primary Social activity action OR preview-availability callout (inside scroll for 200%).
        if (availability == SocialPreviewAvailability.available)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('alertDetailOpenSocial'),
              onPressed: () => context.push('/child/${alert.childId}/social'),
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(l10n.socialAlertOpenActivity),
            ),
          )
        else
          _PreviewUnavailableCard(availability: availability),
        const SizedBox(height: AppSpace.lg),
        const Divider(),
        // 4. Conversation guide.
        CoachCardSection(card: coachCard),
        // 5. Keep /alerts reachable when launched cold from a notification tap.
        if (showAllAlertsButton) ...[
          const SizedBox(height: AppSpace.lg),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              key: const ValueKey('alertDetailAllAlerts'),
              onPressed: () => context.go('/alerts'),
              child: Text(l10n.socialAlertViewAll),
            ),
          ),
        ],
      ],
    );
  }
}

class _PreviewUnavailableCard extends StatelessWidget {
  final SocialPreviewAvailability availability;
  const _PreviewUnavailableCard({required this.availability});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final noPerm = availability == SocialPreviewAvailability.noPermission;
    return Container(
      key: ValueKey(noPerm ? 'alertDetailPreviewNoPerm' : 'alertDetailPreviewExpired'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: tokens.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                noPerm ? Icons.lock_outline : Icons.info_outline,
                size: 20,
                color: tokens.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  noPerm
                      ? l10n.socialAlertPreviewNoPermissionTitle
                      : l10n.socialAlertPreviewExpiredTitle,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            noPerm
                ? l10n.socialAlertPreviewNoPermissionBody
                : l10n.socialAlertPreviewExpiredBody,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
