import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';
import '../../providers/social_provider.dart';
import '../../push/restart_alert_text.dart';
import '../../push/sos_fix_text.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../children/phone_setup_section.dart';
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';
import '../map/family_map_screen.dart'
    show FamilyMapScreen, MapFocus, mapIsAvailable;
import '../rules/app_picker.dart' show AppIconBadge;
import '../social/social_screen.dart' show socialAppIcon, socialAppLabel;
import '../social/social_vote_controls.dart';
import 'access_request_actions.dart';
import 'app_alert_presentation.dart';
import 'sos_alert_actions.dart';

/// Shared per-category localized body formatter used by both [AlertsScreen] and
/// [AlertDetailScreen] so notification-opened details stay consistent with the feed dialog.
String formatGeneralAlertBody(
  Alert alert, {
  required AppLocalizations l10n,
  required String localeName,
  DateTime? now,
}) {
  final isEnglish = localeName.startsWith('en');
  if (alert.category == 'sos') {
    return '';
  }
  if (alert.category == 'web_threat') {
    final domain = alert.metadata['domain']?.toString().trim() ?? '';
    final base = isEnglish && alert.body.trim().isNotEmpty
        ? alert.body.trim()
        : '';
    final detail = domain.isNotEmpty
        ? l10n.blockedSiteDomainLine(ltrIsolate(domain))
        : l10n.blockedSiteNamesNotCollected;
    return base.isEmpty ? detail : '$base\n$detail';
  }
  if (alert.category == 'device_restarted') {
    return RestartAlertText.tryFormat(
          alert,
          l10n: l10n,
          localeName: localeName,
          now: now,
        ) ??
        (isEnglish ? alert.body : '');
  }
  final rawParams = alert.metadata['bodyParams'];
  final params = rawParams is Map
      ? Map<String, dynamic>.from(rawParams)
      : <String, dynamic>{};
  final bodyKey = alert.metadata['bodyKey'];
  String stringParam(String name) {
    final value = params[name];
    return value is String ? value : '';
  }

  String fallback() => isEnglish ||
          (bodyKey != 'alertBodySetupCompleted' &&
              bodyKey != 'alertBodySetupIncomplete' &&
              bodyKey != 'alertBodyDataCleared')
      ? alert.body
      : '';
  switch (bodyKey) {
    case 'alertBodySetupCompleted':
      final childName = stringParam('childName');
      if (childName.isNotEmpty)
        return l10n.alertBodySetupCompleted(firstStrongIsolate(childName));
    case 'alertBodySetupIncomplete':
      final childName = stringParam('childName');
      if (childName.isEmpty) break;
      final isolatedName = firstStrongIsolate(childName);
      final rawCount = params['count'];
      final count = rawCount is num &&
              rawCount.isFinite &&
              rawCount > 0 &&
              rawCount == rawCount.roundToDouble()
          ? rawCount.toInt()
          : null;
      if (count == null)
        return l10n.alertBodySetupIncompleteGeneric(isolatedName);
      final rawMissing = alert.metadata['missing'];
      late final String steps;
      if (rawMissing is List) {
        if (rawMissing.isEmpty ||
            rawMissing.any((grant) => grant is! String || grant.isEmpty)) {
          return l10n.alertBodySetupIncompleteGeneric(isolatedName);
        }
        steps = rawMissing
            .map((grant) => PhoneSetupSection.grantLabel(l10n, grant as String))
            .join(l10n.listSeparator);
      } else {
        final rawSteps = params['steps'];
        if (!isEnglish || rawSteps is! String || rawSteps.isEmpty) {
          return l10n.alertBodySetupIncompleteGeneric(isolatedName);
        }
        steps = rawSteps;
      }
      return l10n.alertBodySetupIncomplete(isolatedName, count, ': $steps');
    case 'alertBodyDataCleared':
      final model = stringParam('model');
      if (model.isNotEmpty) return l10n.alertBodyDataCleared(ltrIsolate(model));
  }
  return fallback();
}

/// Whether [category] uses the dedicated #972 full-screen social alert detail route.
bool isSocialAlertCategory(String category) =>
    category == 'social_concern' || category == 'gaming_chat';

String? socialVoteEventId(Alert alert) {
  const eligibleCategories = {
    'social_concern',
    'gaming_chat',
    'ai_concern',
    'cyberbullying',
    'self_harm',
    'grooming',
  };
  if (!eligibleCategories.contains(alert.category)) return null;
  final eventId =
      alert.metadata['latestSourceEventId']?.toString().trim() ?? '';
  return eventId.isEmpty ? null : eventId;
}

/// Availability of the encrypted Social activity preview for a social alert.
enum SocialPreviewAvailability {
  /// Guardian is authorized and at least one matching event exists (or is still loading).
  available,

  /// Guardian account lacks the `social` permission (`403 permission_required`).
  noPermission,

  /// Vault query succeeded, but no matching encrypted preview is stored or it has expired.
  expired,

  /// Transient network, timeout, or server failure while checking the Social preview endpoint.
  transientError,
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
  AsyncValue<List<SocialConcernEvent>> eventsAsync, {
  String? exactConcernId,
}) {
  return eventsAsync.when(
    loading: () => SocialPreviewAvailability.available,
    error: (err, _) {
      if (err is DioException) {
        final perm = ReadPermissionRequired.from(err);
        if (perm != null && perm.permission == 'social') {
          return SocialPreviewAvailability.noPermission;
        }
      }
      return SocialPreviewAvailability.transientError;
    },
    data: (events) {
      if (exactConcernId != null) {
        return events.any((event) =>
                event.id == exactConcernId && event.preview.isNotEmpty)
            ? SocialPreviewAvailability.available
            : SocialPreviewAvailability.expired;
      }
      if (events.isEmpty) return SocialPreviewAvailability.expired;
      final appKey =
          alert.metadata['app']?.toString().trim().toLowerCase() ?? '';
      if (appKey.isEmpty) return SocialPreviewAvailability.available;
      final hasAppMatch =
          events.any((e) => e.app.trim().toLowerCase() == appKey);
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
    final remoteAlert = ref.watch(alertByIdProvider(alertId));
    final alertAsync = initialAlert != null &&
            initialAlert!.category != 'app_blocked'
        ? AsyncValue<AlertLookupResult>.data(
            AlertLookupResult.found(initialAlert!))
        : remoteAlert.when(
            data: (result) => AsyncValue<AlertLookupResult>.data(
              initialAlert != null && result.status != AlertLookupStatus.found
                  ? AlertLookupResult.found(initialAlert!)
                  : result,
            ),
            loading: () => initialAlert == null
                ? const AsyncValue<AlertLookupResult>.loading()
                : AsyncValue<AlertLookupResult>.data(
                    AlertLookupResult.found(initialAlert!)),
            error: (error, stackTrace) => initialAlert == null
                ? AsyncValue<AlertLookupResult>.error(error, stackTrace)
                : AsyncValue<AlertLookupResult>.data(
                    AlertLookupResult.found(initialAlert!)),
          );

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
      body: alertAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ErrorRetryView(
              message:
                  friendlyErrorText(l10n, err, () => l10n.alertsLoadFailed),
              onRetry: () {
                ref.invalidate(alertsProvider(const AlertFilter()));
                ref.invalidate(alertByIdProvider(alertId));
              },
            ),
            const SizedBox(height: AppSpace.sm),
            OutlinedButton(
              onPressed: () => context.go('/alerts'),
              child: Text(l10n.socialAlertViewAll),
            ),
          ],
        ),
        data: (result) {
          if (result.status == AlertLookupStatus.incompleteScan) {
            return Column(
              key: const ValueKey('alertDetailLookupIncomplete'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ErrorRetryView(
                  message: l10n.alertsLoadFailed,
                  onRetry: () {
                    ref.invalidate(alertsProvider(const AlertFilter()));
                    ref.invalidate(alertByIdProvider(alertId));
                  },
                ),
                const SizedBox(height: AppSpace.sm),
                OutlinedButton(
                  onPressed: () => context.go('/alerts'),
                  child: Text(l10n.socialAlertViewAll),
                ),
              ],
            );
          }
          final alert = result.alert;
          if (alert == null) {
            return _AlertUnavailableView(
                onOpenAllAlerts: () => context.go('/alerts'));
          }
          if (!isSocialAlertCategory(alert.category)) {
            return _GeneralAlertDetailBody(
              alert: alert,
              showAllAlertsButton: !canPop,
              nowProvider: nowProvider,
            );
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
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Text(l10n.socialAlertUnavailableBody,
                    style: theme.textTheme.bodyMedium),
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

class _SocialAlertDetailBody extends ConsumerStatefulWidget {
  final Alert alert;
  final bool showAllAlertsButton;
  final DateTime Function()? nowProvider;

  const _SocialAlertDetailBody({
    required this.alert,
    required this.showAllAlertsButton,
    this.nowProvider,
  });

  @override
  ConsumerState<_SocialAlertDetailBody> createState() =>
      _SocialAlertDetailBodyState();
}

class _SocialAlertDetailBodyState
    extends ConsumerState<_SocialAlertDetailBody> {
  @override
  void initState() {
    super.initState();
    // #1029: opening the detail screen (via feed tap or push tap) clears any "+N new" badge.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(alertsSeenProvider.notifier).markAlertOpened(widget.alert);
      }
    });
  }

  List<String> _concernTypesOf(Alert a) {
    final raw = a.metadata['concernTypes'];
    if (raw is List)
      return [for (final t in raw) '$t'.trim()]
          .where((s) => s.isNotEmpty)
          .toList();
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final showAllAlertsButton = widget.showAllAlertsButton;
    final nowProvider = widget.nowProvider;
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final isEnglish = context.localeName.startsWith('en');

    final overview = ref.watch(familyProvider).valueOrNull;
    final child =
        overview?.children.where((c) => c.id == alert.childId).firstOrNull;
    final device = alert.deviceId != null
        ? overview?.devices.where((d) => d.id == alert.deviceId).firstOrNull
        : null;

    final appKey = alert.metadata['app']?.toString().trim().toLowerCase() ?? '';
    final appLabel = appKey.isEmpty ? null : socialAppLabel(appKey, l10n);
    final concernTypes = _concernTypesOf(alert);
    final title = alert.hasSocialCountSummary && appLabel != null
        ? l10n.socialAlertCountTitle(
            alert.socialMessageCount, ltrIsolate(appLabel))
        : l10n.alertTitleFor(
            alert.category,
            alert.title,
            isEnglish: isEnglish,
            tamperType: alert.metadata['type']?.toString(),
          );
    final latestAt = alert.effectiveTimestamp;
    final latestClock = latestAt == null
        ? ''
        : ltrIsolate(normalizeDigits(
            DateFormat('HH:mm', 'en').format(latestAt.toLocal())));
    final contactName = alert.socialContactName;
    final contactDisplay = contactName != null
        ? firstStrongIsolate(contactName)
        : l10n.socialAlertUnknownContact;
    final senderLine = l10n.socialAlertFromContactOnly(contactDisplay);
    final countLatestLine =
        alert.hasSocialCountSummary && latestClock.isNotEmpty
            ? l10n.socialAlertLatestAt(latestClock)
            : null;

    final sevDot = tokens.severityDot(alert.severity);
    final sevText = tokens.severityText(alert.severity);

    final contextParts = <String>[
      if (child != null && child.displayName.isNotEmpty) child.displayName,
      if (device != null && device.model.isNotEmpty) ltrIsolate(device.model),
    ];

    final primary = alert.metadata['primarySocialEventId'];
    final concernId = primary is String && primary.isNotEmpty ? primary : null;
    final eventsProvider = concernId == null
        ? socialEventsProvider(alert.childId)
        : socialConcernProvider((childId: alert.childId, eventId: concernId));
    final eventsAsync = ref.watch(eventsProvider);
    final availability = resolveSocialPreviewAvailability(alert, eventsAsync,
        exactConcernId: concernId);
    final latestSourceEventId = socialVoteEventId(alert);
    final coachCard = coachCardFor(alert.category, concernTypes);

    return ListView(
      key: const ValueKey('alertDetailScroll'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
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
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
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
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpace.xs),
        ],
        Text(
          senderLine,
          key: const ValueKey('alertDetailCountSub'),
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: tokens.onSurfaceVariant),
        ),
        if (countLatestLine != null) ...[
          const SizedBox(height: 2),
          Text(
            countLatestLine,
            key: const ValueKey('alertDetailCountLatest'),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ] else if (alert.createdAt != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(
            formatAlertLocalTime(
              alert.createdAt!,
              l10n: l10n,
              localeName: context.localeName,
              now: nowProvider?.call(),
            ),
            key: const ValueKey('alertDetailTime'),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: AppSpace.md),
        // 2. Short localized framing (never message content).
        if (appLabel != null) ...[
          Text(
            l10n.socialAlertFlaggedInApp(ltrIsolate(appLabel)),
            key: const ValueKey('alertDetailFraming'),
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        // 3. Primary Social activity action OR preview-availability / retry callout (inside scroll for 200%).
        if (availability == SocialPreviewAvailability.available) ...[
          if (concernId == null) ...[
            const _PreviewUnavailableCard(
                availability: SocialPreviewAvailability.expired),
            const SizedBox(height: AppSpace.sm),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('alertDetailOpenSocial'),
              onPressed: () => context.push(Uri(
                path: '/child/${alert.childId}/social',
                queryParameters:
                    concernId == null ? null : {'concernId': concernId},
              ).toString()),
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(l10n.socialAlertOpenActivity),
            ),
          ),
        ] else if (availability == SocialPreviewAvailability.transientError)
          _PreviewRetryCard(
            message: friendlyErrorText(
              l10n,
              eventsAsync.error ?? Exception('preview_unavailable'),
              () => l10n.alertsLoadFailed,
            ),
            onRetry: () => ref.invalidate(eventsProvider),
          )
        else
          _PreviewUnavailableCard(availability: availability),
        if (latestSourceEventId != null &&
            availability != SocialPreviewAvailability.noPermission &&
            availability != SocialPreviewAvailability.expired) ...[
          const SizedBox(height: AppSpace.lg),
          SocialVoteControls(eventId: latestSourceEventId),
        ],
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
      key: ValueKey(
          noPerm ? 'alertDetailPreviewNoPerm' : 'alertDetailPreviewExpired'),
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
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            noPerm
                ? l10n.socialAlertPreviewNoPermissionBody
                : l10n.socialAlertPreviewExpiredBody,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PreviewRetryCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _PreviewRetryCard({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('alertDetailPreviewRetry'),
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
              Icon(Icons.cloud_off_outlined,
                  size: 20, color: tokens.onSurfaceVariant),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: tokens.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          FilledButton.tonalIcon(
            key: const ValueKey('alertDetailPreviewRetryButton'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l10n.retry),
          ),
        ],
      ),
    );
  }
}

class AppAlertLeading extends StatelessWidget {
  final Alert alert;
  final AppAlertIdentity identity;

  const AppAlertLeading(
      {super.key, required this.alert, required this.identity});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final request = isAccessRequestAlert(alert);
    final statusColor =
        request ? tokens.severityInfoText : tokens.onSurfaceVariant;
    final packageId = appAlertPackageId(alert);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: request
                ? tokens.severityInfoText.withValues(alpha: 0.12)
                : tokens.surfaceVariant,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(request ? Icons.pan_tool : Icons.block,
              size: 21, color: statusColor),
        ),
        const SizedBox(width: AppSpace.xs),
        AppIconBadge(
          app: InstalledApp(
            packageId: packageId,
            label: identity.name,
            iconUrl: identity.installed?.iconUrl,
          ),
          size: 36,
        ),
      ],
    );
  }
}

/// General full-screen presentation for non-social alerts opened via `/alerts/:id`
/// (e.g., `app_blocked`, `tamper`, `web_blocked`). Never queries Social previews or shows
/// the Social activity CTA.
class _GeneralAlertDetailBody extends ConsumerWidget {
  final Alert alert;
  final bool showAllAlertsButton;
  final DateTime Function()? nowProvider;

  const _GeneralAlertDetailBody({
    required this.alert,
    required this.showAllAlertsButton,
    this.nowProvider,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final isEnglish = context.localeName.startsWith('en');

    final overview = ref.watch(familyProvider).valueOrNull;
    final child =
        overview?.children.where((c) => c.id == alert.childId).firstOrNull;
    final device = alert.deviceId != null
        ? overview?.devices.where((d) => d.id == alert.deviceId).firstOrNull
        : null;
    final isAppBlocked = alert.category == 'app_blocked';
    final installed = isAppBlocked
        ? alertInstalledAppsReport(
            ref.watch(installedAppsByDeviceProvider(alert.childId)).valueOrNull,
            alert.deviceId,
          )
        : null;
    final identity = resolveAppAlertIdentity(alert, installed);
    final childName = child?.displayName ?? l10n.childFallback;

    final title = isAppBlocked
        ? appAlertTitle(
            alert: alert,
            localeName: context.localeName,
            childName: childName,
            identity: identity,
          )
        : l10n.alertTitleFor(
            alert.category,
            alert.title,
            isEnglish: isEnglish,
            tamperType: alert.metadata['type']?.toString(),
          );
    final sevDot = tokens.severityDot(alert.severity);
    final contextParts = <String>[
      if (child != null && child.displayName.isNotEmpty)
        isAppBlocked
            ? firstStrongIsolate(child.displayName)
            : child.displayName,
      if (device != null && device.model.isNotEmpty) ltrIsolate(device.model),
    ];
    final coachCard = coachCardFor(alert.category, const []);
    final body = isAppBlocked
        ? appAlertBody(
            alert: alert,
            localeName: context.localeName,
            childName: childName,
            identity: identity,
          )
        : formatGeneralAlertBody(
            alert,
            l10n: l10n,
            localeName: context.localeName,
            now: nowProvider?.call(),
          );
    final voteEventId = socialVoteEventId(alert);
    final voteEventsAsync = voteEventId == null
        ? null
        : ref.watch(socialEventsProvider(alert.childId));
    final voteAvailability = voteEventsAsync == null
        ? null
        : resolveSocialPreviewAvailability(alert, voteEventsAsync);

    return ListView(
      key: const ValueKey('alertDetailGeneralScroll'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isAppBlocked)
              AppAlertLeading(alert: alert, identity: identity)
            else
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(Icons.notifications_active_outlined,
                    color: sevDot, size: 24),
              ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                title,
                key: const ValueKey('alertDetailTitle'),
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        if (contextParts.isNotEmpty) ...[
          Text(
            contextParts.join(' · '),
            key: const ValueKey('alertDetailChildDevice'),
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
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
            style: theme.textTheme.bodySmall
                ?.copyWith(color: tokens.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.md),
        ],
        if (body.trim().isNotEmpty) ...[
          Text(
            body,
            key: const ValueKey('alertDetailBody'),
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: AppSpace.md),
        ],
        if (isAccessRequestAlert(alert)) ...[
          AccessRequestActions(
            alert: alert,
            identity: identity,
            nowProvider: nowProvider,
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        if (alert.category == 'sos' && alert.location != null) ...[
          Builder(builder: (_) {
            final fix = alert.location!;
            final text = SosFixText.of(
                alert, fix, nowProvider?.call() ?? DateTime.now());
            final accuracy = text.accuracyClause(l10n, fix);
            return Column(
              key: const ValueKey('alert-sos-location'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text.locationLine(l10n, fix.isolatedCoords),
                  key: const ValueKey('alert-sos-location-line'),
                  style: theme.textTheme.bodyLarge,
                ),
                if (accuracy != null)
                  Text(
                    accuracy,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                const SizedBox(height: AppSpace.md),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.xs,
                  children: sosAlertActions(
                    l10n: l10n,
                    mapAvailable: mapIsAvailable(theme.platform),
                    onShowOnMap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FamilyMapScreen(
                            focus: MapFocus.fromFix(
                              fix,
                              label: text.pinCaption(l10n, title),
                              accuracyM: fix.accuracyM,
                            ),
                          ),
                        ),
                      );
                    },
                    onOpenInMaps: () async {
                      final uri = Uri.parse(
                        'https://www.google.com/maps/search/?api=1&query=${fix.lat},${fix.lng}',
                      );
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    },
                    onCopy: () async {
                      await Clipboard.setData(
                          ClipboardData(text: fix.copyText));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(l10n.alertCoordinatesCopied)));
                      }
                    },
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: AppSpace.lg),
        ],
        if (alert.category == 'tamper' &&
            alert.metadata['type']?.toString() == 'block_bypass' &&
            alert.metadata['layout']?.toString() == 'call') ...[
          Text(
            l10n.alertCallBypassNote,
            key: const ValueKey('alert-call-bypass-note'),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        if (voteEventId != null &&
            voteAvailability != SocialPreviewAvailability.noPermission &&
            voteAvailability != SocialPreviewAvailability.expired) ...[
          SocialVoteControls(eventId: voteEventId),
          const SizedBox(height: AppSpace.lg),
        ],
        const Divider(),
        CoachCardSection(card: coachCard),
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
