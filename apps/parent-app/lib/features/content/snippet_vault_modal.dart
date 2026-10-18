import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';

/// Severity indicator color for vault modal.
Color snippetSeverityColor(String severity) => switch (severity.toLowerCase()) {
      'warning' => Colors.amber,
      'critical' => Colors.red,
      _ => Colors.blue,
    };

/// Feature: Snippet Vault Decryption Viewer modal for parents.
///
/// Displays decrypted content from the AES-256-GCM vault, with encryption
/// trust indicators, concern categories, copy utility, and embedded
/// conversation coaching ([CoachCardSection]).
class SnippetVaultModal extends StatelessWidget {
  final String title;
  final String snippet;
  final String severity;
  final List<String> concernTypes;
  final String? sourceLabel;
  final DateTime? timestamp;

  const SnippetVaultModal({
    super.key,
    required this.title,
    required this.snippet,
    required this.severity,
    this.concernTypes = const [],
    this.sourceLabel,
    this.timestamp,
  });

  /// Opens the modal as a responsive bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String snippet,
    required String severity,
    List<String> concernTypes = const [],
    String? sourceLabel,
    DateTime? timestamp,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SnippetVaultModal(
        title: title,
        snippet: snippet,
        severity: severity,
        concernTypes: concernTypes,
        sourceLabel: sourceLabel,
        timestamp: timestamp,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final sevColor = snippetSeverityColor(severity);
    final formattedTime = timestamp != null
        ? DateFormat.yMMMd(context.localeName).add_Hms().format(timestamp!.toLocal())
        : null;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 32),
        children: [
          Row(
            children: [
              Icon(Icons.lock_open, color: sevColor, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title.isEmpty ? l10n.decryptedVaultContent : title,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (sourceLabel != null || formattedTime != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (sourceLabel != null)
                  Text(sourceLabel!, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold)),
                if (sourceLabel != null && formattedTime != null)
                  Text(' · ', style: theme.textTheme.bodySmall),
                if (formattedTime != null)
                  Text(formattedTime, style: theme.textTheme.bodySmall),
                const Spacer(),
                Chip(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: sevColor.withValues(alpha: 0.15),
                  side: BorderSide(color: sevColor.withValues(alpha: 0.4)),
                  label: Text(
                    l10n.severityName(severity),
                    style: theme.textTheme.labelSmall?.copyWith(color: sevColor, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // Security trust banner
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.encryptedFamilyVault,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.vaultEncryptionDesc,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Decrypted content snippet
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sevColor.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l10n.decryptedContent, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: snippet));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.contentCopied)));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.copy, size: 14),
                            const SizedBox(width: 4),
                            Text(l10n.copy, style: theme.textTheme.labelSmall),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  snippet.isEmpty ? l10n.noPreviewContent : snippet,
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          if (concernTypes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.detectedConcernTypes, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in concernTypes)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(c, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          CoachCardSection(card: coachCardFor('social_concern', concernTypes)),
        ],
      ),
    );
  }
}
