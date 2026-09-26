import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';

const _kCategories = ['pornography', 'gambling', 'violence', 'drugs', 'social_media', 'chat']; // legacy extras; the recommended 13 live in kRecommendedCategories (models.dart)
const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// BUG-002 hardening: stored rules are 1..7 per the API contract, but never index out
/// of range — unknown values render as '?' instead of throwing (RangeError crashed the tab).
String _weekdayLabel(int d) => (d >= 1 && d <= 7) ? _kWeekdays[d - 1] : '?';

/// Parses "HH:mm" into a [TimeOfDay]; falls back to [fallback].
TimeOfDay parseTime(String value, TimeOfDay fallback) {
  final parts = value.split(':');
  if (parts.length != 2) return fallback;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return fallback;
  return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
}

String formatTime(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Rules editor for one child (spec §7.9): Screen time / Web filter /
/// Apps / Routines. Save PUTs the full RuleSet to /v1/rules/:childId.
class RulesEditorScreen extends ConsumerStatefulWidget {
  final String childId;
  const RulesEditorScreen({super.key, required this.childId});

  @override
  ConsumerState<RulesEditorScreen> createState() => _RulesEditorScreenState();
}

class _RulesEditorScreenState extends ConsumerState<RulesEditorScreen> {
  RuleSet _draft = const RuleSet();
  bool _loaded = false;
  bool _saving = false;
  String? _error;
  final _allowedDomains = TextEditingController();
  final _blockedDomains = TextEditingController();

  @override
  void dispose() {
    _allowedDomains.dispose();
    _blockedDomains.dispose();
    super.dispose();
  }

  void _applyLoaded(RuleSet ruleSet) {
    if (_loaded) return;
    _loaded = true;
    _draft = ruleSet;
    _allowedDomains.text = ruleSet.webFilter.allowedDomains.join(', ');
    _blockedDomains.text = ruleSet.webFilter.blockedDomains.join(', ');
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // NOTE: the server PATCH-merges, so we always send the full object.
      await ref.read(apiClientProvider).raw.put('/v1/rules/${widget.childId}', data: _draft.toJson());
      ref.invalidate(rulesProvider(widget.childId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rules saved')));
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      setState(() => _error = data is Map ? '${data['error'] ?? data['message'] ?? e.message}' : e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(context: context, initialTime: initial);

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(rulesProvider(widget.childId));
    ref.listen(rulesProvider(widget.childId), (_, next) => next.whenData(_applyLoaded));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit rules'),
        actions: [
          if (_saving)
            const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            FilledButton(onPressed: _loaded ? _save : null, child: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load rules: $e')),
        data: (ruleSet) {
          _applyLoaded(ruleSet);
          return _buildTabs(context);
        },
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    if (_error != null) {
      return Column(
        children: [
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text('Dismiss'))],
          ),
          const Expanded(child: SizedBox()),
        ],
      );
    }
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Screen time'), Tab(text: 'Web filter'), Tab(text: 'Apps'), Tab(text: 'Routines')]),
          Expanded(
            child: TabBarView(
              children: [_buildScreenTime(), _buildWebFilter(), _buildApps(), _buildRoutines()],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Screen time tab ----

  Widget _buildScreenTime() {
    final st = _draft.screenTime;
    void update(ScreenTimeRule Function(ScreenTimeRule) f) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: f(st), webFilter: _draft.webFilter, appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, updatedAt: _draft.updatedAt));

    Widget timeTile(String label, String value, ValueChanged<TimeOfDay> onPicked) => ListTile(
          title: Text(label),
          trailing: TextButton(
            onPressed: () async {
              final t = await _pickTime(parseTime(value, const TimeOfDay(hour: 12, minute: 0)));
              if (t != null) onPicked(t);
            },
            child: Text(value),
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Daily limit: ${st.dailyLimitMinutes} min', style: Theme.of(context).textTheme.titleMedium),
        Slider(value: st.dailyLimitMinutes.toDouble(), min: 15, max: 600, divisions: 39, label: '${st.dailyLimitMinutes} min', onChanged: (v) => update((s) => ScreenTimeRule(dailyLimitMinutes: v.round(), weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const SizedBox(height: 8),
        Text('Weekend limit: ${st.weekendLimitMinutes} min', style: Theme.of(context).textTheme.titleMedium),
        Slider(value: st.weekendLimitMinutes.toDouble(), min: 15, max: 600, divisions: 39, label: '${st.weekendLimitMinutes} min', onChanged: (v) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: v.round(), bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const Divider(height: 32),
        Text('Bedtime', style: Theme.of(context).textTheme.titleMedium),
        timeTile('Starts', st.bedtimeStart, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: formatTime(t), bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        timeTile('Ends', st.bedtimeEnd, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: formatTime(t), schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const Divider(height: 32),
        Text('School hours', style: Theme.of(context).textTheme.titleMedium),
        timeTile('Starts', st.schoolStart, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: formatTime(t), schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        timeTile('Ends', st.schoolEnd, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: formatTime(t), schoolDays: s.schoolDays))),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 1; i <= 7; i++)
              FilterChip(
                label: Text(_kWeekdays[i - 1]),
                selected: st.schoolDays.contains(i),
                onSelected: (sel) => update((s) {
                  final days = {...s.schoolDays};
                  sel ? days.add(i) : days.remove(i);
                  return ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: days.toList()..sort());
                }),
              ),
          ],
        ),
      ],
    );
  }

  // ---- Web filter tab ----

  /// Recommended-protection switch state: ON only when every recommended
  /// category is blocked; any partial selection renders OFF (tristate-off).
  bool get _recommendedOn => kRecommendedCategories.every(_draft.webFilter.blockedCategories.contains);

  Future<void> _toggleRecommended(bool enable, void Function(WebFilterRule Function(WebFilterRule)) apply) async {
    if (enable) {
      apply((w) {
        final cats = {...w.blockedCategories, ...kRecommendedCategories};
        return WebFilterRule(blockedCategories: cats.toList(), allowedDomains: w.allowedDomains, blockedDomains: w.blockedDomains, safeSearchEnforced: w.safeSearchEnforced);
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recommended protection'),
        content: const Text('Disabling recommended categories reduces protection. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Continue')),
        ],
      ),
    );
    if (confirmed == true) {
      if (!mounted) return;
      apply((w) {
        final cats = {...w.blockedCategories}..removeAll(kRecommendedCategories);
        return WebFilterRule(blockedCategories: cats.toList(), allowedDomains: w.allowedDomains, blockedDomains: w.blockedDomains, safeSearchEnforced: w.safeSearchEnforced);
      });
    }
  }

  Widget _buildWebFilter() {
    final wf = _draft.webFilter;
    void update(WebFilterRule Function(WebFilterRule) f) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: f(wf), appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, updatedAt: _draft.updatedAt));

    List<String> splitDomains(String text) =>
        text.split(',').map((d) => d.trim()).where((d) => d.isNotEmpty).toList();

    // Recommended categories first, then any legacy extras still editable.
    final categories = [...kRecommendedCategories, for (final c in _kCategories) if (!kRecommendedCategories.contains(c)) c];

    return ListView(
      key: const ValueKey('webFilterList'),
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Recommended protection'),
          subtitle: const Text('Block all 13 recommended categories'),
          value: _recommendedOn,
          onChanged: (v) => _toggleRecommended(v, update),
        ),
        const Divider(height: 24),
        Text('Blocked categories', style: Theme.of(context).textTheme.titleMedium),
        for (final c in categories)
          CheckboxListTile(
            dense: true,
            title: Text(c),
            value: wf.blockedCategories.contains(c),
            onChanged: (v) => update((w) {
              final cats = {...w.blockedCategories};
              v == true ? cats.add(c) : cats.remove(c);
              return WebFilterRule(blockedCategories: cats.toList(), allowedDomains: w.allowedDomains, blockedDomains: w.blockedDomains, safeSearchEnforced: w.safeSearchEnforced);
            }),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _allowedDomains,
          decoration: const InputDecoration(labelText: 'Allowed domains (comma-separated)', border: OutlineInputBorder()),
          onChanged: (v) => update((w) => WebFilterRule(blockedCategories: w.blockedCategories, allowedDomains: splitDomains(v), blockedDomains: w.blockedDomains, safeSearchEnforced: w.safeSearchEnforced)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _blockedDomains,
          decoration: const InputDecoration(labelText: 'Blocked domains (comma-separated)', border: OutlineInputBorder()),
          onChanged: (v) => update((w) => WebFilterRule(blockedCategories: w.blockedCategories, allowedDomains: w.allowedDomains, blockedDomains: splitDomains(v), safeSearchEnforced: w.safeSearchEnforced)),
        ),
        SwitchListTile(
          title: const Text('Enforce SafeSearch'),
          value: wf.safeSearchEnforced,
          onChanged: (v) => update((w) => WebFilterRule(blockedCategories: w.blockedCategories, allowedDomains: w.allowedDomains, blockedDomains: w.blockedDomains, safeSearchEnforced: v)),
        ),
      ],
    );
  }

  // ---- Apps tab ----

  Widget _buildApps() {
    void update(List<AppRule> rules) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: rules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, updatedAt: _draft.updatedAt));

    void updateAlwaysAllowed(List<String> apps) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: apps, updatedAt: _draft.updatedAt));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Feature #9: apps that stay open during bedtime, school time,
        // pause and routines.
        Text('Always allowed', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'These apps stay open during bedtime, school time, pause and routines.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_draft.alwaysAllowedApps.isEmpty)
          const Text('No always-allowed apps yet')
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final pkg in _draft.alwaysAllowedApps)
                InputChip(
                  label: Text(pkg),
                  onDeleted: () => updateAlwaysAllowed([..._draft.alwaysAllowedApps]..remove(pkg)),
                ),
            ],
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add app'),
          onPressed: () async {
            final pkg = await showDialog<String>(context: context, builder: (_) => const _AddAlwaysAllowedDialog());
            if (pkg != null && !_draft.alwaysAllowedApps.contains(pkg)) {
              updateAlwaysAllowed([..._draft.alwaysAllowedApps, pkg]);
            }
          },
        ),
        const Divider(height: 32),
        for (var i = 0; i < _draft.appRules.length; i++)
          _AppRuleTile(
            key: ValueKey(_draft.appRules[i].packageId),
            rule: _draft.appRules[i],
            onChanged: (r) => update([..._draft.appRules]..[i] = r),
            onRemove: () => update([..._draft.appRules]..removeAt(i)),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add app rule'),
          onPressed: () async {
            final rule = await showDialog<AppRule>(context: context, builder: (_) => const _AddAppRuleDialog());
            if (rule != null) update([..._draft.appRules, rule]);
          },
        ),
      ],
    );
  }

  // ---- Routines tab ----

  Widget _buildRoutines() {
    void update(List<Routine> routines) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: _draft.appRules, routines: routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, updatedAt: _draft.updatedAt));

    Future<void> edit([Routine? existing]) async {
      final result = await showDialog<Routine>(context: context, builder: (_) => _RoutineDialog(existing: existing));
      if (result == null) return;
      if (existing == null) {
        update([..._draft.routines, result]);
      } else {
        update([for (final r in _draft.routines) r.id == existing.id ? result : r]);
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final r in _draft.routines)
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(r.name),
              subtitle: Text('${r.startTime}–${r.endTime} · ${r.days.map(_weekdayLabel).join(' ')}'),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => update([..._draft.routines]..remove(r))),
              onTap: () => edit(r),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.add), label: const Text('Add routine'), onPressed: () => edit()),
      ],
    );
  }
}

/// One editable app-rule row: allow/block/time_limit segmented control plus
/// a minutes field shown for time_limit rules.
class _AppRuleTile extends StatefulWidget {
  final AppRule rule;
  final ValueChanged<AppRule> onChanged;
  final VoidCallback onRemove;
  const _AppRuleTile({super.key, required this.rule, required this.onChanged, required this.onRemove});

  @override
  State<_AppRuleTile> createState() => _AppRuleTileState();
}

class _AppRuleTileState extends State<_AppRuleTile> {
  late final TextEditingController _minutes = TextEditingController(text: widget.rule.dailyLimitMinutes?.toString() ?? '');

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(r.appName, style: Theme.of(context).textTheme.titleSmall),),
                IconButton(icon: const Icon(Icons.delete_outline), onPressed: widget.onRemove),
              ],
            ),
            Text(r.packageId, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'allow', label: Text('Allow')),
                ButtonSegment(value: 'block', label: Text('Block')),
                ButtonSegment(value: 'time_limit', label: Text('Time limit')),
              ],
              selected: {r.action},
              onSelectionChanged: (sel) => widget.onChanged(AppRule(packageId: r.packageId, appName: r.appName, action: sel.first, dailyLimitMinutes: r.dailyLimitMinutes)),
            ),
            if (r.action == 'time_limit') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Limit (minutes/day)', border: OutlineInputBorder(), isDense: true),
                onChanged: (v) => widget.onChanged(AppRule(packageId: r.packageId, appName: r.appName, action: r.action, dailyLimitMinutes: int.tryParse(v))),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Dialog collecting package id + app name for a new app rule.
class _AddAppRuleDialog extends StatefulWidget {
  const _AddAppRuleDialog();

  @override
  State<_AddAppRuleDialog> createState() => _AddAppRuleDialogState();
}

class _AddAppRuleDialogState extends State<_AddAppRuleDialog> {
  final _packageId = TextEditingController();
  final _appName = TextEditingController();

  @override
  void dispose() {
    _packageId.dispose();
    _appName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add app rule'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _appName, decoration: const InputDecoration(labelText: 'App name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _packageId, decoration: const InputDecoration(labelText: 'Package ID (e.g. com.example.app)', border: OutlineInputBorder())),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_packageId.text.trim().isEmpty) return;
            Navigator.of(context).pop(AppRule(packageId: _packageId.text.trim(), appName: _appName.text.trim().isEmpty ? _packageId.text.trim() : _appName.text.trim(), action: 'allow'));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Feature #9 dialog: collects just a package id for the always-allowed list.
class _AddAlwaysAllowedDialog extends StatefulWidget {
  const _AddAlwaysAllowedDialog();

  @override
  State<_AddAlwaysAllowedDialog> createState() => _AddAlwaysAllowedDialogState();
}

class _AddAlwaysAllowedDialogState extends State<_AddAlwaysAllowedDialog> {
  final _packageId = TextEditingController();

  @override
  void dispose() {
    _packageId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add always-allowed app'),
      content: TextField(
        controller: _packageId,
        decoration: const InputDecoration(labelText: 'Package ID (e.g. com.example.app)', border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final pkg = _packageId.text.trim();
            if (pkg.isEmpty) return;
            Navigator.of(context).pop(pkg);
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Create/edit dialog for a Routine (name, window, weekday chips, app lists).
class _RoutineDialog extends StatefulWidget {
  final Routine? existing;
  const _RoutineDialog({this.existing});

  @override
  State<_RoutineDialog> createState() => _RoutineDialogState();
}

class _RoutineDialogState extends State<_RoutineDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _blocked = TextEditingController(text: widget.existing?.blockedApps.join(', ') ?? '');
  late final TextEditingController _allowed = TextEditingController(text: widget.existing?.allowedApps.join(', ') ?? '');
  late TimeOfDay _start = parseTime(widget.existing?.startTime ?? '17:00', const TimeOfDay(hour: 17, minute: 0));
  late TimeOfDay _end = parseTime(widget.existing?.endTime ?? '19:00', const TimeOfDay(hour: 19, minute: 0));
  late Set<int> _days = {...?widget.existing?.days};

  @override
  void dispose() {
    _name.dispose();
    _blocked.dispose();
    _allowed.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final t = await showTimePicker(context: context, initialTime: isStart ? _start : _end);
    if (t != null) setState(() => isStart ? _start = t : _end = t);
  }

  List<String> _split(String text) => text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add routine' : 'Edit routine'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: () => _pick(true), child: Text('Start ${formatTime(_start)}'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text('End ${formatTime(_end)}'))),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 1; i <= 7; i++)
                  FilterChip(
                    label: Text(_kWeekdays[i - 1]),
                    selected: _days.contains(i),
                    onSelected: (sel) => setState(() => sel ? _days.add(i) : _days.remove(i)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(controller: _blocked, decoration: const InputDecoration(labelText: 'Blocked apps (comma-separated)', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: _allowed, decoration: const InputDecoration(labelText: 'Allowed apps (comma-separated)', border: OutlineInputBorder())),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().isEmpty) return;
            Navigator.of(context).pop(Routine(
              id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
              name: _name.text.trim(),
              startTime: formatTime(_start),
              endTime: formatTime(_end),
              days: _days.toList()..sort(),
              blockedApps: _split(_blocked.text),
              allowedApps: _split(_allowed.text),
            ));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
