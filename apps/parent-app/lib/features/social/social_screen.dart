import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/social_provider.dart';
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';

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
        appBar: AppBar(title: const Text('Social monitoring')),
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
        padding: const EdgeInsets.all(16),
        children: [
          MonitoringTogglesSection(childId: childId),
          const SizedBox(height: 24),
          ConcernsSection(childId: childId),
          const SizedBox(height: 24),
          CallsSmsSection(childId: childId),
          const SizedBox(height: 24),
          AllowlistSection(childId: childId),
        ],
      );
}

Color socialSeverityColor(String severity) => switch (severity) {
      'warning' => Colors.amber,
      'critical' => Colors.red,
      _ => Colors.blue,
    };

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
      _ => Icons.apps,
    };

String socialAppLabel(String appKey) {
  for (final a in kSocialApps) {
    if (a.appKey == appKey) return a.label;
  }
  return appKey.isEmpty ? 'Unknown app' : appKey[0].toUpperCase() + appKey.substring(1);
}

String formatRelativeTime(DateTime? at) {
  if (at == null) return 'unknown time';
  final diff = DateTime.now().difference(at.toLocal());
  if (diff.isNegative || diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Monitoring saved')));
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: ${e.message}')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(rulesProvider(widget.childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Monitoring', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        rules.when(
          loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text('Failed to load rules: $e'),
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
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save monitoring'),
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
    final events = ref.watch(socialEventsProvider(childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Feature #24: vault trust copy — snippets leave the device encrypted.
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.lock_outline),
            title: Text('Snippets are encrypted with your family key before leaving the device and stored encrypted on your server.'),
          ),
        ),
        const SizedBox(height: 8),
        Text('Concerns', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        events.when(
          loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text('Failed to load concerns: $e'),
          data: (items) => items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: Text('No concerns detected')),
                )
              : Column(
                  children: [
                    for (final e in items)
                      Card(
                        color: socialSeverityColor(e.severity).withValues(alpha: 0.07),
                        child: ExpansionTile(
                          leading: Icon(socialAppIcon(e.app), color: socialSeverityColor(e.severity)),
                          title: Text(e.contact.isEmpty ? 'Unknown contact' : e.contact),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${socialAppLabel(e.app)} · ${formatRelativeTime(e.createdAt)}'),
                              if (e.concernTypes.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
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
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: Text(e.preview.isEmpty ? 'No preview available' : e.preview),
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
    final activity = ref.watch(activityProvider(childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Calls & texts', style: Theme.of(context).textTheme.titleMedium),
        // NOTE: iOS agent cannot observe calls/texts (no public API) — keep
        // the section but tell parents why it may stay empty.
        Text('iOS does not support call/text monitoring.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        activity.when(
          loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text('Failed to load activity: $e'),
          data: (items) {
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('No calls or texts yet')),
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
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
                    child: Text(_dayLabel(day), style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final e in groups[day]!)
                    Card(
                      child: ListTile(
                        dense: true,
                        leading: Icon(e.type == 'call'
                            ? (e.direction == 'outgoing' ? Icons.call_made : Icons.call_received)
                            : Icons.sms_outlined),
                        title: Text(e.number ?? 'Unknown number'),
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

  String _dayLabel(String key) {
    if (key == 'Unknown') return key;
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    return DateFormat('EEEE, MMM d, yyyy').format(d);
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
    final items = _items;
    if (items == null) return;
    setState(() => _saving = true);
    try {
      final ruleSet = ref.read(rulesProvider(widget.childId)).valueOrNull ?? const RuleSet();
      final body = ruleSet.toJson();
      body['contactAllowlist'] = List.of(items);
      await ref.read(apiClientProvider).raw.put('/v1/rules/${widget.childId}', data: body);
      ref.invalidate(rulesProvider(widget.childId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allowlist saved')));
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: ${e.message}')));
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
    final rules = ref.watch(rulesProvider(widget.childId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Trusted contacts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Numbers here never raise social concerns.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        rules.when(
          loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text('Failed to load rules: $e'),
          data: (ruleSet) {
            _applyLoaded(ruleSet);
            final items = _items!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (items.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final n in items)
                        InputChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(n),
                          onDeleted: () => setState(() => items.remove(n)),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _input,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Phone number',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(icon: const Icon(Icons.add), tooltip: 'Add', onPressed: _add),
                  ),
                  onSubmitted: (_) => _add(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save allowlist'),
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
