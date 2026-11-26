import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// A single accepted blocked-site or blocked-app attempt parsed from
/// `alert.metadata['blockGroup']['attempts']` (contract locked on #1228).
class BlockedAttemptEntry {
  final DateTime at;
  final String? site;
  final String? app;

  const BlockedAttemptEntry({
    required this.at,
    this.site,
    this.app,
  });
}

/// Returns `'app'` for app-blocked groups, `'web'` for web-blocked groups.
String blockedAttemptKind(Alert alert) {
  final group = alert.metadata['blockGroup'];
  if (group is Map) {
    final kind = group['kind']?.toString().trim().toLowerCase();
    if (kind == 'app' || kind == 'web') return kind!;
  }
  return alert.category == 'app_blocked' ? 'app' : 'web';
}

/// Parses `alert.metadata['blockGroup']['attempts']` into newest-first entries.
/// Malformed entries or entries without a parseable ISO-8601 `at` are skipped.
List<BlockedAttemptEntry> parseBlockedAttempts(Alert alert) {
  final group = alert.metadata['blockGroup'];
  if (group is! Map) return const [];
  final raw = group['attempts'];
  if (raw is! List || raw.isEmpty) return const [];

  final parsed = <BlockedAttemptEntry>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final atRaw = item['at']?.toString().trim() ?? '';
    final at = DateTime.tryParse(atRaw);
    if (at == null) continue;
    final siteRaw = item['site']?.toString().trim();
    final appRaw = item['app']?.toString().trim();
    parsed.add(
      BlockedAttemptEntry(
        at: at,
        site: siteRaw != null && siteRaw.isNotEmpty ? siteRaw : null,
        app: appRaw != null && appRaw.isNotEmpty ? appRaw : null,
      ),
    );
  }
  parsed.sort((a, b) => b.at.compareTo(a.at));
  return parsed;
}

/// Renders the per-attempt list for grouped `web_threat` and `app_blocked`
/// alerts (#1222 / #1228), newest first.
///
/// - Web entries show the site name when `site` is present (`SITE_NAMES_ENABLED`
///   on), or localized "Blocked site" when omitted.
/// - App entries show `app` when present, or localized "Blocked app" when omitted.
/// - When `alert.attemptCount > entries.length`, shows a "Showing X of Y" caption.
class BlockedAttemptsSection extends StatelessWidget {
  final Alert alert;

  const BlockedAttemptsSection({
    super.key,
    required this.alert,
  });

  String _formatLocalTime(DateTime utcOrLocal) {
    final local = utcOrLocal.toLocal();
    return ltrIsolate(normalizeDigits(DateFormat('HH:mm', 'en').format(local)));
  }

  @override
  Widget build(BuildContext context) {
    final entries = parseBlockedAttempts(alert);
    if (entries.isEmpty) return const SizedBox.shrink();

    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final kind = blockedAttemptKind(alert);
    final total = alert.attemptCount > entries.length ? alert.attemptCount : entries.length;
    final isCapped = total > entries.length;

    return Card(
      key: const ValueKey('blockedAttemptsCard'),
      color: tokens.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: tokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xxs,
              children: [
                Text(
                  l10n.blockedAttemptsTitle,
                  key: const ValueKey('blockedAttemptsTitle'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: tokens.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isCapped)
                  Text(
                    l10n.blockedAttemptsShowingOf(
                      ltrIsolate('${entries.length}'),
                      ltrIsolate('$total'),
                    ),
                    key: const ValueKey('blockedAttemptsCapNote'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) Divider(height: 1, color: tokens.border),
              _AttemptRow(
                index: i,
                label: kind == 'app'
                    ? (entries[i].app != null
                        ? firstStrongIsolate(entries[i].app!)
                        : l10n.alertCategoryAppBlocked)
                    : (entries[i].site != null
                        ? ltrIsolate(entries[i].site!)
                        : l10n.alertCategoryWebThreat),
                timeLabel: _formatLocalTime(entries[i].at),
                icon: kind == 'app' ? Icons.block_outlined : Icons.public_off_outlined,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AttemptRow extends StatelessWidget {
  final int index;
  final String label;
  final String timeLabel;
  final IconData icon;

  const _AttemptRow({
    required this.index,
    required this.label,
    required this.timeLabel,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('blockedAttemptRow-$index'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: tokens.onSurfaceVariant),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            timeLabel,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
