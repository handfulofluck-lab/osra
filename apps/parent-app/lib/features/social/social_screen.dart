import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/social_provider.dart';
import '../../theme/app_tokens.dart';
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';
import '../content/snippet_vault_modal.dart';
import '../../api/permission_errors.dart';

/// The eight social apps the Android agent can monitor via Accessibility
/// (spec #2); apps absent from the RuleSet default to ON.
const kSocialApps = [
  (appKey: 'whatsapp', label: 'WhatsApp'),
  (appKey: 'instagram', label: 'Instagram'),
  (appKey: 'tiktok', label: 'TikTok'),
  (appKey: 'snapchat', label: 'Snapchat'),
  (appKey: 'x', label: 'X'),
  (appKey: 'discord', label: 'Discord'),
  (appKey: 'roblox', label: 'Roblox'),
  (appKey: 'line', label: 'LINE'),
];

/// Standalone social-monitoring screen (route `/child/:id/social`).
class SocialScreen extends ConsumerWidget {
  final String childId;
  const SocialScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: Text(context.l10n.socialMonitoringTitle)),
        body: SocialSectionsView(childId: childId),
      );
}

/// The four shared social sections (monitoring toggles, concerns vault,
/// calls & texts timeline, contact allowlist), embeddable both in
/// [SocialScreen] and in the child-detail Social tab.
class SocialSectionsView extends StatelessWidget {
  final String childId;
  const SocialSectionsView({super.key, required this.childId});

  @override
  Widget build(BuildContext context) => ListView(
        key: const ValueKey('socialSectionsList'),
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          MonitoringTogglesSection(childId: childId),
          const SizedBox(height: AppSpace.xl),
          ConcernsSection(childId: childId),
          const SizedBox(height: AppSpace.xl),
          CallsSmsSection(childId: childId),
          const SizedBox(height: AppSpace.xl),
          AllowlistSection(childId: childId),
        ],
      );
}

Color socialSeverityColor(String severity, [BuildContext? context]) =>
    (context?.tokens ?? AppTokens.light).severityDot(severity);

// NOTE: no brand icons in Material — closest generic glyphs per app.
IconData socialAppIcon(String appKey) => switch (appKey) {
      'whatsapp' => Icons.chat,
      'instagram' => Icons.photo_camera_outlined,
      'tiktok' => Icons.music_note,
      'snapchat' => Icons.bolt,
      'x' => Icons.alternate_email,
      'discord' => Icons.headset_mic_outlined,
      'roblox' => Icons.sports_esports,
      'line' => Icons.message_outlined,
      'youtube' => Icons.smart_display_outlined,
      'telegram' => Icons.send_outlined,
      'reddit' => Icons.forum_outlined,
      'messenger' => Icons.chat_bubble_outline,
      _ => Icons.apps,
    };

String socialAppLabel(String appKey, [AppLocalizations? l10n]) {
  for (final a in kSocialApps) {
    if (a.appKey == appKey) return a.label;
  }
  return appKey.isEmpty ? (l10n?.unknownApp ?? 'Unknown app') : appKey[0].toUpperCase() + appKey.substring(1);
}

String formatRelativeTime(DateTime? at, [AppLocalizations? l10n]) {
  if (at == null) return l10n?.timeUnknown ?? 'unknown time';
  final diff = DateTime.now().difference(at.toLocal());
  if (diff.isNegative || diff.inMinutes < 1) return l10n?.relativeJustNow ?? 'just now';
  if (diff.inHours < 1) return l10n?.relativeMinutesAgo(diff.inMinutes) ?? '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return l10n?.relativeHoursAgo(diff.inHours) ?? '${diff.inHours}h ago';
  return l10n?.relativeDaysAgo(diff.inDays) ?? '${diff.inDays}d ago';
}

String formatDurationMmSs(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Section (a): per-app monitoring switches, initialized from
/// RuleSet.socialMonitoring (absent = ON); Save PUTs the full ruleset with
/// the merged socialMonitoring map.
class MonitoringTogglesSection extends ConsumerStatefulWidget {
  final String childId;
  const MonitoringTogglesSection({super.key, required this.childId});

  @override
  ConsumerState<MonitoringTogglesSection> createState() => _MonitoringTogglesSectionState();
}

class _MonitoringTogglesSectionState extends ConsumerState<MonitoringTogglesSection> {
  Map<String, bool>? _draft;
  bool _saving = false;

  void _applyLoaded(RuleSet ruleSet) {
    if (_draft != null) return;
    _draft = {for (final a in kSocialApps) a.appKey: ruleSet.socialMonitoring[a.appKey] ?? true};
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final draft = _draft;
    if (draft == null) return;
    setState(() => _saving = true);
    try {
      final ruleSet = ref.read(rulesProvider(widget.childId)).valueOrNull ?? const RuleSet();
      final body = ruleSet.toJson();
      // NOTE: merge server-side map under the local draft so keys we do not
      // render here (future apps) survive the PATCH-merge.
      body['socialMonitoring'] = {...ruleSet.socialMonitoring, ...draft};
      await ref.read(apiClientProvider).raw.put('/v1/rules/${widget.childId}', data: body);
      ref.invalidate(rulesProvider(widget.childId));
      // Issue #475 follow-up: a rule write must refresh the family snapshot too (#501 review).
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.monitoringSaved)));
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.saveFailed('${e.message}'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.monitoring, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        rules.when(
          loading: () => const Padding(padding: EdgeInsets.all(AppSpace.lg), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(readErrorText(l10n, e, () => l10n.rulesLoadFailed('$e'))),
          data: (ruleSet) {
            _applyLoaded(ruleSet);
            final draft = _draft!;
            return Column(
              children: [
                for (final a in kSocialApps)
                  SwitchListTile(
                    dense: true,
                    title: Text(a.label),
                    secondary: Icon(socialAppIcon(a.appKey)),
                    value: draft[a.appKey] ?? true,
                    onChanged: (v) => setState(() => draft[a.appKey] = v),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? l10n.saving : l10n.saveMonitoring),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Section (b): the decrypted concerns vault as severity-colored cards with
/// concern chips and an expandable preview.
class ConcernsSection extends ConsumerWidget {
  final String childId;
  const ConcernsSection({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final events = ref.watch(socialEventsProvider(childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Feature #24: vault trust copy — snippets leave the device encrypted.
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.lock_outline),
            title: Text(l10n.vaultTrustCopy),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(l10n.concerns, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        events.when(
          loading: () => const Padding(padding: EdgeInsets.all(AppSpace.lg), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(readErrorText(l10n, e, () => l10n.rulesLoadFailed('$e'))),
          data: (items) => items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                  child: Center(child: Text(l10n.noConcernsDetected)),
                )
              : Column(
                  children: [
                    for (final e in items)
                      Card(
                        color: socialSeverityColor(e.severity, context).withValues(alpha: 0.07),
                        child: ExpansionTile(
                          leading: Icon(socialAppIcon(e.app), color: socialSeverityColor(e.severity, context)),
                          title: Text(e.contact.isEmpty ? l10n.unknownContact : e.contact),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${socialAppLabel(e.app, l10n)} · ${formatRelativeTime(e.createdAt, l10n)}'),
                              if (e.concernTypes.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: AppSpace.xs),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: AppSpace.xs,
                                    children: [
                                      for (final t in e.concernTypes)
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(t, style: Theme.of(context).textTheme.bodySmall),
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          children: [
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
                                child: Text(e.preview.isEmpty ? l10n.noPreviewAvailable : e.preview),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: TextButton.icon(
                                  icon: const Icon(Icons.lock_open, size: 16),
                                  label: Text(l10n.viewInDecryptionVault),
                                  onPressed: () => SnippetVaultModal.show(
                                    context,
                                    title: e.contact.isEmpty ? l10n.socialMessage : e.contact,
                                    snippet: e.preview,
                                    severity: e.severity,
                                    concernTypes: e.concernTypes,
                                    sourceLabel: socialAppLabel(e.app, l10n),
                                    timestamp: e.createdAt,
                                  ),
                                ),
                              ),
                            ),
                            // Feature #16: same coaching card as alert details,
                            // keyed off the AI concern types.
                            CoachCardSection(card: coachCardFor('social_concern', e.concernTypes)),
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

/// Section (#6): merged calls + SMS timeline, day-grouped newest first.
class CallsSmsSection extends ConsumerWidget {
  final String childId;
  const CallsSmsSection({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final activity = ref.watch(activityProvider(childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.callsAndTexts, style: Theme.of(context).textTheme.titleMedium),
        // NOTE: iOS agent cannot observe calls/texts (no public API) — keep
        // the section but tell parents why it may stay empty.
        Text(l10n.iosNoCallMonitoring, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppSpace.xs),
        activity.when(
          loading: () => const Padding(padding: EdgeInsets.all(AppSpace.lg), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(readErrorText(l10n, e, () => l10n.rulesLoadFailed('$e'))),
          data: (items) {
            if (items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                child: Center(child: Text(l10n.noCallsOrTexts)),
              );
            }
            // Group by local day, most recent first.
            final groups = <String, List<ActivityEvent>>{};
            final order = <String>[];
            for (final e in items) {
              final day = e.ts == null ? 'Unknown' : DateFormat('yyyy-MM-dd').format(e.ts!.toLocal());
              if (!groups.containsKey(day)) {
                groups[day] = [];
                order.add(day);
              }
              groups[day]!.add(e);
            }
            order.sort((a, b) => b.compareTo(a));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final day in order) ...[
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.xs, AppSpace.md, AppSpace.xs, AppSpace.xxs),
                    child: Text(_dayLabel(context, day), style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final e in groups[day]!)
                    Card(
                      child: ListTile(
                        dense: true,
                        leading: Icon(e.type == 'call'
                            ? (e.direction == 'outgoing' ? Icons.call_made : Icons.call_received)
                            : Icons.sms_outlined),
                        title: Text(e.number ?? l10n.unknownNumber),
                        subtitle: e.type == 'sms' ? Text(_truncateSms(e.bodyPreview)) : null,
                        trailing: e.type == 'call' ? Text(formatDurationMmSs(e.durationSec)) : null,
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  String _dayLabel(BuildContext context, String key) {
    if (key == 'Unknown') return context.l10n.unknown;
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    return DateFormat('EEEE, MMM d, yyyy', context.localeName).format(d);
  }

  /// SMS previews are capped at 120 chars server-side; truncate defensively.
  String _truncateSms(String preview) =>
      preview.length > 120 ? '${preview.substring(0, 120)}…' : preview;
}

/// Section (c): trusted-contact allowlist chip editor; numbers are
/// normalized to digits before saving via PUT rules contactAllowlist.
class AllowlistSection extends ConsumerStatefulWidget {
  final String childId;
  const AllowlistSection({super.key, required this.childId});

  @override
  ConsumerState<AllowlistSection> createState() => _AllowlistSectionState();
}

class _AllowlistSectionState extends ConsumerState<AllowlistSection> {
  final _input = TextEditingController();
  List<String>? _items;
  bool _saving = false;

  void _applyLoaded(RuleSet ruleSet) {
    if (_items != null) return;
    _items = List.of(ruleSet.contactAllowlist);
  }

  /// Keep digits only — '+1 (555) 123-4567' becomes '15551234567'.
  static String normalizePhone(String raw) => raw.replaceAll(RegExp(r'\D'), '');

  void _add() {
    final digits = normalizePhone(_input.text);
    if (digits.isEmpty) return;
    setState(() {
      final items = _items ??= <String>[];
      if (!items.contains(digits)) items.add(digits);
      _input.clear();
    });
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final items = _items;
    if (items == null) return;
    setState(() => _saving = true);
    try {
      final ruleSet = ref.read(rulesProvider(widget.childId)).valueOrNull ?? const RuleSet();
      final body = ruleSet.toJson();
      body['contactAllowlist'] = List.of(items);
      await ref.read(apiClientProvider).raw.put('/v1/rules/${widget.childId}', data: body);
      ref.invalidate(rulesProvider(widget.childId));
      // Issue #475 follow-up: a rule write must refresh the family snapshot too (#501 review).
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.allowlistSaved)));
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.saveFailed('${e.message}'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.trustedContacts, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        Text(l10n.trustedContactsDesc, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppSpace.sm),
        rules.when(
          loading: () => const Padding(padding: EdgeInsets.all(AppSpace.lg), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text(readErrorText(l10n, e, () => l10n.rulesLoadFailed('$e'))),
          data: (ruleSet) {
            _applyLoaded(ruleSet);
            final items = _items!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (items.isNotEmpty)
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.xs,
                    children: [
                      for (final n in items)
                        InputChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(n),
                          onDeleted: () => setState(() => items.remove(n)),
                        ),
                    ],
                  ),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _input,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: l10n.phoneNumberLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(icon: const Icon(Icons.add), tooltip: l10n.add, onPressed: _add),
                  ),
                  onSubmitted: (_) => _add(),
                ),
                const SizedBox(height: AppSpace.sm),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? l10n.saving : l10n.saveAllowlist),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
