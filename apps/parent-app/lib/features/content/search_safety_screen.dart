import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/content_provider.dart';
import '../../theme/app_tokens.dart';
import '../social/social_screen.dart' show formatRelativeTime;
import 'snippet_vault_modal.dart';

/// Icon for search engines or platforms.
IconData searchEngineIcon(String engine) => switch (engine.toLowerCase()) {
      'youtube' => Icons.smart_display_outlined,
      'google' => Icons.travel_explore,
      'bing' => Icons.search,
      'duckduckgo' => Icons.shield_outlined,
      'yahoo' => Icons.language,
      _ => Icons.search,
    };

/// Severity dot colour for search query cards; the text role is used for the
/// severity chip, because the pinned amber dot is not readable as text.
Color searchSeverityColor(String severity, [BuildContext? context]) =>
    (context?.tokens ?? AppTokens.light).severityDot(severity);

/// The severity label in the app's language. The API sends `info`/`warning`/`critical`; an Arabic
/// screen showing `CRITICAL` in Latin capitals was the last English string on this page.
String _severityLabel(BuildContext context, String severity) => switch (severity.toLowerCase()) {
      'critical' => context.l10n.severityCritical,
      'warning' => context.l10n.severityWarning,
      _ => context.l10n.severityInfo,
    };

/// Screen displaying flagged search queries for a child (Track 1 & 2 content monitoring).
/// Queries are decrypted on-demand from the server-side AES-256-GCM vault.
class SearchSafetyScreen extends ConsumerWidget {
  final String childId;
  const SearchSafetyScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searches = ref.watch(searchEventsProvider(childId));
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.searchSafetyTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refresh,
            onPressed: () => ref.invalidate(searchEventsProvider(childId)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(searchEventsProvider(childId)),
        child: searches.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(AppSpace.xl),
            children: [
              Center(
                child: Text(l10n.searchSafetyLoadFailed('$e'), textAlign: TextAlign.center),
              ),
              const SizedBox(height: AppSpace.lg),
              Center(
                child: FilledButton.tonal(
                  onPressed: () => ref.invalidate(searchEventsProvider(childId)),
                  child: Text(l10n.retry),
                ),
              ),
            ],
          ),
          data: (items) {
            if (items.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(AppSpace.xl),
                children: [
                  // 48 is a deliberate empty-state offset, not a gap on the scale.
                  const SizedBox(height: 48),
                  Icon(Icons.shield_outlined, size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: AppSpace.lg),
                  Text(
                    l10n.searchSafetyEmptyTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    l10n.searchSafetyEmptyBody,
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }

            return ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.lock_outline),
                    title: Text(l10n.searchSafetyVaultNotice),
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(l10n.searchSafetyFlaggedCount(items.length), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpace.sm),
                for (final item in items)
                  _SearchEventCard(childId: childId, item: item),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SearchEventCard extends StatelessWidget {
  final String childId;
  final SearchEventItem item;

  const _SearchEventCard({required this.childId, required this.item});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sevColor = searchSeverityColor(item.severity, context);
    final sevText = context.tokens.severityText(item.severity);
    final engineLabel = item.engine.isEmpty
        ? l10n.searchSafetyEngineFallback
        : item.engine[0].toUpperCase() + item.engine.substring(1);

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      color: sevColor.withValues(alpha: 0.05),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => SnippetVaultModal.show(
          context,
          title: l10n.searchSafetyVaultTitle(item.query),
          snippet: item.query,
          severity: item.severity,
          concernTypes: item.concernTypes,
          sourceLabel: engineLabel,
          timestamp: item.createdAt,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(searchEngineIcon(item.engine), color: sevColor, size: 20),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      '$engineLabel · ${formatRelativeTime(item.createdAt, l10n)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: sevColor.withValues(alpha: 0.15),
                    side: BorderSide(color: sevColor.withValues(alpha: 0.3)),
                    label: Text(
                      _severityLabel(context, item.severity),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: sevText, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                item.query.isEmpty ? l10n.searchSafetyEmptyQuery : item.query,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (item.concernTypes.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: AppSpace.xs,
                  children: [
                    for (final t in item.concernTypes)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(l10n.searchRiskCategory(t), style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(l10n.searchSafetyViewVault, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                  const SizedBox(width: AppSpace.xs),
                  Icon(Icons.chevron_right, size: 16, color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
