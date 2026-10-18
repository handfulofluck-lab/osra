import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';

/// Parent dashboard: grid of child cards with live status, pull-to-refresh
/// and a consent-first "Add child" flow.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider);
    final unread = ref.watch(unacknowledgedCountProvider);
    // Keep the live WS channel subscribed so the activity chips update (#29).
    ref.watch(wsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('OSRA'),
        actions: [
          IconButton(icon: const Icon(Icons.map_outlined), tooltip: 'Family map', onPressed: () => context.push('/map')),
          IconButton(
            tooltip: 'Alerts',
            onPressed: () => context.push('/alerts'),
            icon: Badge(
              isLabelVisible: unread.hasValue && (unread.value ?? 0) > 0,
              label: Text('${unread.value ?? 0}'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => context.push(switch (v) {
              'family' => '/family',
              'appearance' => '/settings/appearance',
              _ => '/settings/digests',
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'family', child: Text('Family members')),
              PopupMenuItem(value: 'appearance', child: Text('Appearance')),
              PopupMenuItem(value: 'digests', child: Text('Digest preferences')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
      body: family.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load family: $e')),
        data: (overview) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(familyProvider),
          child: overview.children.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 200),
                    Center(child: Text('No children yet — tap "Add child"')),
                  ],
                )
              : GridView.count(
                  // NOTE: one column under 400px — two 110px-wide cards made
                  // the card content overflow on 320px-wide screens.
                  crossAxisCount: MediaQuery.sizeOf(context).width < 400 ? 1 : 2,
                  padding: const EdgeInsets.all(AppSpace.md),
                  mainAxisSpacing: AppSpace.md,
                  crossAxisSpacing: AppSpace.md,
                  children: [for (final child in overview.children) ChildCard(child: child)],
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog(context: context, builder: (_) => const AddChildDialog()),
        icon: const Icon(Icons.person_add),
        label: const Text('Add child'),
      ),
    );
  }
}

/// Grid card for one child: avatar, status pill, battery, location snippet
/// and today's screen-time progress against the daily limit.
class ChildCard extends ConsumerWidget {
  final Child child;
  const ChildCard({super.key, required this.child});

  Color _statusColor(AppTokens tokens, String status) => switch (status) {
        'online' => tokens.ok,
        'locked' => tokens.warn,
        'sos' => tokens.danger,
        _ => tokens.onSurfaceVariant,
      };

  /// Online only when the device checked in within the last 3 minutes.
  static String _effectiveStatus(Device d) {
    final last = d.lastSeen;
    final online = last != null && DateTime.now().difference(last) < const Duration(minutes: 3);
    return online ? 'online' : 'offline';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(familyProvider).valueOrNull;
    final device = overview?.devicesFor(child.id).firstOrNull;
    final location = ref.watch(locationProvider(child.id)).valueOrNull;
    final rules = ref.watch(rulesProvider(child.id)).valueOrNull;
    final dailyLimit = rules?.screenTime.dailyLimitMinutes ?? 0;
    final progress = dailyLimit > 0 ? (child.screenTimeTodayMinutes / dailyLimit).clamp(0.0, 1.0) : 0.0;
    final live = ref.watch(liveActivityProvider)[child.id];
    final wellbeing = ref.watch(wellbeingProvider(child.id)).valueOrNull;

    final tokens = context.tokens;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/child/${child.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(child: Text(child.initials)),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: Text(child.displayName, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
                ],
              ),
              if (live != null && live.isFresh()) ...[
                const SizedBox(height: AppSpace.xs),
                LiveActivityChip(childId: child.id, activity: live),
              ],
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (device != null)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(Icons.circle, size: 10, color: _statusColor(tokens, _effectiveStatus(device))),
                      label: Text(_effectiveStatus(device)),
                    ),
                  if (device != null && device.batteryPct > 0)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(device.batteryPct <= 20 ? Icons.battery_alert : Icons.battery_std, size: 14),
                      label: Text('${device.batteryPct}%'),
                    ),
                  InternetPill(child: child),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  const Icon(Icons.location_on_outlined, size: 14),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      location == null
                          ? 'No location yet'
                          : '${location.lat.toStringAsFixed(4)}, ${location.lng.toStringAsFixed(4)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Screen time', style: Theme.of(context).textTheme.bodySmall),
                  // NOTE: flexible + ellipsis — narrow cards overflowed this row.
                  Flexible(
                    child: Text('${child.screenTimeTodayMinutes} / ${dailyLimit > 0 ? dailyLimit : '—'} min',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              LinearProgressIndicator(value: dailyLimit > 0 ? progress : null),
              if (wellbeing != null) ...[
                const SizedBox(height: AppSpace.sm),
                WellbeingRow(score: wellbeing),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Feature #29 chip: '● {app} · {minutesToday}m today', green while a
/// `live_activity` WS event is fresh (< 2 min); tapping opens the child detail.
class LiveActivityChip extends StatelessWidget {
  final String childId;
  final LiveActivity activity;
  const LiveActivityChip({super.key, required this.childId, required this.activity});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => context.push('/child/$childId'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
        child: Text(
          '● ${activity.app} · ${activity.minutesToday}m today',
          key: ValueKey('liveChip-$childId'),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tokens.ok),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Feature #28: compact wellbeing score ring (score/100, red < 50, amber < 75,
/// green otherwise) with a tooltip breakdown of the sub-scores.
class WellbeingRow extends StatelessWidget {
  final WellbeingScore score;
  const WellbeingRow({super.key, required this.score});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // Legacy rings keep their pinned Material thresholds (Colors.red/amber/
    // green in light mode) through the token layer, so the colours can differ
    // per brightness without changing the documented thresholds.
    final color = score.score < 50
        ? tokens.wellbeingLow
        : score.score < 75
            ? tokens.wellbeingMid
            : tokens.wellbeingHigh;
    final breakdown = score.breakdown;
    String part(String k) => '$k: ${breakdown[k] ?? '—'}';
    return Tooltip(
      message: '${part('usage')} · ${part('social')} · ${part('safety')}',
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: (score.score / 100).clamp(0.0, 1.0),
                  strokeWidth: 4,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.15),
                ),
                Text(
                  '${score.score}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        height: 1,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          // NOTE: flexible — the row overflowed 320px-wide cards.
          Flexible(child: Text('Wellbeing ${score.score}/100', style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// One-tap "pause the internet" pill (Feature #11): red "Paused" when the
/// child's internet is sinkholed, green "Internet" otherwise. Tapping toggles
/// via a confirm dialog; the flip is optimistic and reverts on error.
class InternetPill extends ConsumerWidget {
  final Child child;
  const InternetPill({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(internetPausedProvider(child.id)).valueOrNull ?? false;
    final tokens = context.tokens;
    final color = paused ? tokens.danger : tokens.ok;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => toggleInternetWithConfirm(context, ref, child, paused),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(paused ? Icons.wifi_off : Icons.wifi, size: 14, color: color),
            const SizedBox(width: AppSpace.xs),
            Text(paused ? 'Paused' : 'Internet', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// Family Link style confirm dialog for the internet pill; POSTs the toggle
/// only on confirm.
Future<void> toggleInternetWithConfirm(BuildContext context, WidgetRef ref, Child child, bool paused) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(paused ? 'Resume internet for ${child.displayName}?' : 'Pause internet for ${child.displayName}?'),
      content: Text(paused ? 'All apps and sites work again.' : 'Educational apps keep working.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(paused ? 'Resume' : 'Pause')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    if (paused) {
      await resumeInternet(ref, child.id);
    } else {
      await pauseInternet(ref, child.id);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Internet change failed: $e')));
    }
  }
}

/// Two-step add-child dialog: parental consent first (method + jurisdiction
/// matching the family region), then the child's details.
class AddChildDialog extends ConsumerStatefulWidget {
  const AddChildDialog({super.key});

  @override
  ConsumerState<AddChildDialog> createState() => _AddChildDialogState();
}

class _AddChildDialogState extends ConsumerState<AddChildDialog> {
  static const _methods = ['sms_plus', 'kba', 'face_match', 'credit_card'];
  final _name = TextEditingController();
  final _birthYear = TextEditingController();
  String _method = _methods.first;
  late String _jurisdiction;
  bool _consentDone = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _jurisdiction = ref.read(authProvider).family?.region ?? 'US';
  }

  @override
  void dispose() {
    _name.dispose();
    _birthYear.dispose();
    super.dispose();
  }

  /// Advance from the consent step to the child-details step. The consent is
  /// submitted together with the child in [_createChild] (single atomic POST).
  void _recordConsent() => setState(() => _consentDone = true);

  Future<void> _createChild() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).raw.post('/v1/family/children', data: {
        'displayName': _name.text.trim(),
        'birthYear': int.tryParse(_birthYear.text.trim()) ?? DateTime.now().year,
        'consent': {'method': _method, 'jurisdiction': _jurisdiction},
      });
      ref.invalidate(familyProvider);
      if (mounted) Navigator.of(context).pop();
    } on DioException catch (e) {
      // Consent gate: surface the API's 428 message when consent is missing.
      final data = e.response?.data;
      setState(() => _error = data is Map ? '${data['error'] ?? data['message'] ?? e.message}' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return AlertDialog(
      title: Text(_consentDone ? 'Child details' : 'Parental consent'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_consentDone) ...[
              const Text('Verifiable parental consent is required before adding a child (COPPA/GDPR-K).'),
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Consent method', border: OutlineInputBorder()),
                items: [for (final m in _methods) DropdownMenuItem(value: m, child: Text(m))],
                onChanged: (v) => setState(() => _method = v ?? _methods.first),
              ),
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _jurisdiction,
                decoration: const InputDecoration(labelText: 'Jurisdiction', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'US', child: Text('US')),
                  DropdownMenuItem(value: 'EU', child: Text('EU')),
                  DropdownMenuItem(value: 'UK', child: Text('UK')),
                  DropdownMenuItem(value: 'OTHER', child: Text('OTHER')),
                ],
                onChanged: (v) => setState(() => _jurisdiction = v ?? 'US'),
              ),
            ] else ...[
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Child name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _birthYear,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Birth year',
                  border: const OutlineInputBorder(),
                  hintText: '${DateTime.now().year}',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(_error!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : (_consentDone ? _createChild : _recordConsent),
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_consentDone ? 'Add child' : 'Continue'),
        ),
      ],
    );
  }
}

/// Formats a device last-seen timestamp for display.
String formatLastSeen(DateTime? lastSeen) =>
    lastSeen == null ? 'never' : DateFormat.yMMMd().add_Hm().format(lastSeen.toLocal());
