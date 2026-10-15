import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers/content_provider.dart';
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

/// Severity color for search query cards.
Color searchSeverityColor(String severity) => switch (severity.toLowerCase()) {
      'warning' => Colors.amber,
      'critical' => Colors.red,
      _ => Colors.blue,
    };

/// Screen displaying flagged search queries for a child (Track 1 & 2 content monitoring).
/// Queries are decrypted on-demand from the server-side AES-256-GCM vault.
class SearchSafetyScreen extends ConsumerWidget {
  final String childId;
  const SearchSafetyScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searches = ref.watch(searchEventsProvider(childId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search safety'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(searchEventsProvider(childId)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(searchEventsProvider(childId)),
        child: searches.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Text('Failed to load search activity: $e', textAlign: TextAlign.center),
              ),
              const SizedBox(height: 16),
              Center(
                child: FilledButton.tonal(
                  onPressed: () => ref.invalidate(searchEventsProvider(childId)),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
          data: (items) {
            if (items.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 48),
                  Icon(Icons.shield_outlined, size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'No flagged searches detected',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'SafeSearch enforcement and content inspection are active across all supported browsers and apps.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: const ListTile(
                    dense: true,
                    leading: Icon(Icons.lock_outline),
                    title: Text('Search queries are analyzed for safety concerns. High-severity matches are logged to the encrypted family vault.'),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Flagged searches (${items.length})', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
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
    final sevColor = searchSeverityColor(item.severity);
    final engineLabel = item.engine.isEmpty ? 'Search' : item.engine[0].toUpperCase() + item.engine.substring(1);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: sevColor.withValues(alpha: 0.05),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => SnippetVaultModal.show(
          context,
          title: 'Search: "${item.query}"',
          snippet: item.query,
          severity: item.severity,
          concernTypes: item.concernTypes,
          sourceLabel: engineLabel,
          timestamp: item.createdAt,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(searchEngineIcon(item.engine), color: sevColor, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '$engineLabel · ${formatRelativeTime(item.createdAt)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: sevColor.withValues(alpha: 0.15),
                    side: BorderSide(color: sevColor.withValues(alpha: 0.3)),
                    label: Text(
                      item.severity.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: sevColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                item.query.isEmpty ? '(Empty query)' : item.query,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (item.concernTypes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final t in item.concernTypes)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(t, style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('View vault details', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                  const SizedBox(width: 4),
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
