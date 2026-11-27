import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart' show apiClientProvider;
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// `GET /v1/family/privacy`: what is kept and for how long, and where it is stored.
///
/// P-23 rule: these numbers come from the server's own retention settings (the ones its cleanup job
/// applies), never from this file. A missing or unusable value hides its row rather than showing a
/// number the server didn't send.
class PrivacySummary {
  final int? excerptDays;
  final int? alertDays;
  final int? locationDays;

  /// `frankfurt`, `stockholm` or `ireland`; null hides the "Stored in" row.
  final String? storageLocation;
  final String policyUrlEn;
  final String policyUrlAr;

  const PrivacySummary({
    this.excerptDays,
    this.alertDays,
    this.locationDays,
    this.storageLocation,
    this.policyUrlEn = 'https://osratech.com/privacy',
    this.policyUrlAr = 'https://osratech.com/ar/privacy',
  });

  static int? _days(Object? v) => v is int && v > 0 ? v : null;

  factory PrivacySummary.fromJson(Map<String, dynamic> json) {
    final retention = json['retention'] is Map ? json['retention'] as Map : const {};
    final storage = json['storage'] is Map ? json['storage'] as Map : null;
    final urls = json['policyUrls'] is Map ? json['policyUrls'] as Map : const {};
    String url(Object? v, String fallback) =>
        v is String && v.startsWith('https://') ? v : fallback;
    return PrivacySummary(
      excerptDays: _days(retention['messageExcerptDays']),
      alertDays: _days(retention['alertDays']),
      locationDays: _days(retention['locationDays']),
      storageLocation: storage?['area'] == 'eu' ? storage!['location'] as String? : null,
      policyUrlEn: url(urls['en'], 'https://osratech.com/privacy'),
      policyUrlAr: url(urls['ar'], 'https://osratech.com/ar/privacy'),
    );
  }
}

final privacySummaryProvider = FutureProvider.autoDispose<PrivacySummary>((ref) async {
  final res = await ref.read(apiClientProvider).raw.get('/v1/family/privacy');
  final data = res.data;
  if (data is! Map) throw const FormatException('privacy summary is not an object');
  return PrivacySummary.fromJson(Map<String, dynamic>.from(data));
});

/// A period in the unit people say it in: 365 days reads "12 months", 90 days stays "90 days".
String privacyPeriod(AppLocalizations l10n, int days) {
  if (days % 365 == 0) return l10n.privacyMonths(days ~/ 365 * 12);
  return l10n.privacyDays(days);
}

String? privacyStorageLabel(AppLocalizations l10n, String? location) => switch (location) {
      'frankfurt' => l10n.privacyStorageFrankfurt,
      'stockholm' => l10n.privacyStorageStockholm,
      'ireland' => l10n.privacyStorageIreland,
      _ => null,
    };

/// P-23 Privacy and data (UX final decisions, 25 Nov).
///
/// The retention summary sits on top; each privacy action has its own row. Actions are limited to what
/// the server already does: who can see data (Family), a copy of the data (by email, privacy policy §12),
/// consent per child (the existing consent screen, which also withdraws), and account deletion (the
/// existing screen, which asks for the password). Deletion has no cancel window on the server, so none
/// is promised here. "Pause monitoring", "Share a summary with your child" and a self-serve export are
/// left out until the server supports them.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final summary = ref.watch(privacySummaryProvider);
    final family = ref.watch(familyProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          summary.when(
            data: (s) => _RetentionCard(summary: s),
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => _LoadFailed(onRetry: () => ref.invalidate(privacySummaryProvider)),
          ),
          const SizedBox(height: AppSpace.lg),
          _Section(children: [
            _ActionRow(
              key: const ValueKey('privacyWhoCanSee'),
              title: l10n.privacyWhoCanSee,
              subtitle: l10n.privacyWhoCanSeeDesc,
              action: l10n.privacyManage,
              onTap: () => context.push('/family'),
            ),
            _ActionRow(
              key: const ValueKey('privacyCopy'),
              title: l10n.privacyCopyTitle,
              subtitle: l10n.privacyCopyDesc,
              action: l10n.privacyCopyAction,
              onTap: () => launchUrl(
                Uri(scheme: 'mailto', path: 'support@osratech.com', query: 'subject=Data copy request'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ]),
          const SizedBox(height: AppSpace.lg),
          _Section(children: [
            _ActionRow(
              key: const ValueKey('privacyConsent'),
              title: l10n.privacyConsentTitle,
              subtitle: l10n.privacyConsentDesc,
              action: l10n.privacyOpen,
              onTap: () => _openConsent(context, family?.children ?? const []),
            ),
          ]),
          const SizedBox(height: AppSpace.lg),
          _DeleteCard(isOwner: family?.parent.role == 'owner'),
        ],
      ),
    );
  }

  /// One child goes straight to their consent screen; more than one asks which child first.
  Future<void> _openConsent(BuildContext context, List<Child> children) async {
    final l10n = context.l10n;
    if (children.length == 1) {
      await context.push('/child/${children.single.id}/consent');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(l10n.privacyChooseChild, style: Theme.of(sheet).textTheme.titleMedium)),
            if (children.isEmpty) ListTile(title: Text(l10n.privacyNoChildren)),
            for (final child in children)
              ListTile(
                key: ValueKey('privacyConsentChild-${child.id}'),
                title: Text(child.displayName),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(sheet).pop(child.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null && context.mounted) await context.push('/child/$picked/consent');
  }
}

class _RetentionCard extends StatelessWidget {
  const _RetentionCard({required this.summary});
  final PrivacySummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final rows = <(String, String, String)>[
      if (summary.excerptDays != null)
        ('privacyRowExcerpts', l10n.privacyRowExcerpts, privacyPeriod(l10n, summary.excerptDays!)),
      if (summary.alertDays != null) ('privacyRowAlerts', l10n.privacyRowAlerts, privacyPeriod(l10n, summary.alertDays!)),
      if (summary.locationDays != null)
        ('privacyRowLocation', l10n.privacyRowLocation, privacyPeriod(l10n, summary.locationDays!)),
      if (privacyStorageLabel(l10n, summary.storageLocation) case final where?)
        ('privacyRowStoredIn', l10n.privacyRowStoredIn, where),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          children: [
            Text(
              l10n.privacyKeptHeader.toUpperCase(),
              style: text.labelSmall?.copyWith(color: tokens.onSurfaceVariant, letterSpacing: 0.8),
            ),
            TextButton(
              key: const ValueKey('privacyFullDetails'),
              onPressed: () => launchUrl(
                Uri.parse(isArabic ? summary.policyUrlAr : summary.policyUrlEn),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(l10n.privacyFullDetails),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: tokens.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Column(
            children: [
              for (final (key, label, value) in rows)
                Padding(
                  key: ValueKey(key),
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(label, style: text.bodyMedium?.copyWith(color: tokens.onSurfaceVariant)),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Flexible(
                        child: Text(
                          value,
                          textAlign: TextAlign.end,
                          style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: tokens.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      key: const ValueKey('privacyLoadFailed'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.privacyLoadFailed),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton(onPressed: onRetry, child: Text(l10n.privacyRetry)),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: tokens.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleSmall),
                  const SizedBox(height: AppSpace.xxs),
                  Text(subtitle, style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Text(action, style: text.labelLarge?.copyWith(color: tokens.primary)),
            Icon(Icons.chevron_right, color: tokens.primary, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Destructive, so it looks destructive and sits last. The owner deletes the whole family; anyone else
/// deletes only their own account. Both go through the existing screen, which asks for the password.
class _DeleteCard extends StatelessWidget {
  const _DeleteCard({required this.isOwner});
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isOwner ? l10n.privacyDeleteFamilyTitle : l10n.privacyDeleteSelfTitle,
          style: text.titleSmall?.copyWith(color: tokens.danger),
        ),
        const SizedBox(height: AppSpace.xxs),
        Text(
          isOwner ? l10n.privacyDeleteFamilyDesc : l10n.privacyDeleteSelfDesc,
          style: text.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
        ),
      ],
    );
    final deleteButton = OutlinedButton(
      key: const ValueKey('privacyDeleteButton'),
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.danger,
        side: BorderSide(color: tokens.danger),
      ),
      onPressed: () => context.push('/settings/delete-account'),
      child: Text(l10n.privacyDeleteAction),
    );
    return Container(
      key: const ValueKey('privacyDelete'),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: tokens.danger.withValues(alpha: 0.08),
        border: Border.all(color: tokens.danger.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: scale >= 1.5
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                textBlock,
                const SizedBox(height: AppSpace.md),
                Align(alignment: AlignmentDirectional.centerStart, child: deleteButton),
              ],
            )
          : Row(
              children: [
                Expanded(child: textBlock),
                const SizedBox(width: AppSpace.md),
                deleteButton,
              ],
            ),
    );
  }
}
