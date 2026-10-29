import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';

import '../../api/permission_errors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

const _kCategories = ['pornography', 'gambling', 'violence', 'drugs', 'social_media', 'chat']; // legacy extras; the recommended 13 live in kRecommendedCategories (models.dart)

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
    final l10n = context.l10n;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // NOTE: the server PATCH-merges, so we always send the full object.
      await ref.read(apiClientProvider).raw.put('/v1/rules/${widget.childId}', data: _draft.toJson());
      ref.invalidate(rulesProvider(widget.childId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.rulesSaved)));
      }
    } on DioException catch (e) {
      // Issue #437: a rule write can be refused for consent (`428`), and that sentence names no
      // command because this is an edit. `readErrorText` decides; the raw code stays for anything else.
      final data = e.response?.data;
      setState(() => _error = readErrorText(
            l10n,
            e,
            () => data is Map ? '${data['error'] ?? data['message'] ?? e.message}' : (e.message ?? ''),
          ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(context: context, initialTime: initial);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.childId));
    ref.listen(rulesProvider(widget.childId), (_, next) => next.whenData(_applyLoaded));
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.editRules),
        actions: [
          if (_saving)
            const Padding(padding: EdgeInsets.all(AppSpace.lg), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            FilledButton(onPressed: _loaded ? _save : null, child: Text(l10n.save)),
          const SizedBox(width: AppSpace.sm),
        ],
      ),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l10n.rulesLoadFailed('$e'))),
        data: (ruleSet) {
          _applyLoaded(ruleSet);
          return _buildTabs(context);
        },
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    final l10n = context.l10n;
    if (_error != null) {
      return Column(
        children: [
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: () => setState(() => _error = null), child: Text(l10n.dismiss))],
          ),
          const Expanded(child: SizedBox()),
        ],
      );
    }
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: l10n.tabScreenTime),
              Tab(text: l10n.tabWebFilter),
              Tab(text: l10n.tabApps),
              Tab(text: l10n.tabRoutines),
            ],
          ),
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
    final l10n = context.l10n;
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
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(l10n.dailyLimit(st.dailyLimitMinutes), style: Theme.of(context).textTheme.titleMedium),
        Slider(value: st.dailyLimitMinutes.toDouble(), min: 15, max: 600, divisions: 39, label: l10n.minutesShort(st.dailyLimitMinutes), onChanged: (v) => update((s) => ScreenTimeRule(dailyLimitMinutes: v.round(), weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const SizedBox(height: AppSpace.sm),
        Text(l10n.weekendLimit(st.weekendLimitMinutes), style: Theme.of(context).textTheme.titleMedium),
        Slider(value: st.weekendLimitMinutes.toDouble(), min: 15, max: 600, divisions: 39, label: l10n.minutesShort(st.weekendLimitMinutes), onChanged: (v) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: v.round(), bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const Divider(height: AppSpace.xxl),
        Text(l10n.bedtime, style: Theme.of(context).textTheme.titleMedium),
        timeTile(l10n.starts, st.bedtimeStart, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: formatTime(t), bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        timeTile(l10n.ends, st.bedtimeEnd, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: formatTime(t), schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const Divider(height: AppSpace.xxl),
        Text(l10n.schoolHours, style: Theme.of(context).textTheme.titleMedium),
        timeTile(l10n.starts, st.schoolStart, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: formatTime(t), schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        timeTile(l10n.ends, st.schoolEnd, (t) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: formatTime(t), schoolDays: s.schoolDays))),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          children: [
            for (var i = 1; i <= 7; i++)
              FilterChip(
                label: Text(l10n.weekdayShort(i)),
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
    final l10n = context.l10n;
    if (enable) {
      apply((w) {
        final cats = {...w.blockedCategories, ...kRecommendedCategories};
        return w.copyWith(blockedCategories: cats.toList());
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.recommendedProtection),
        content: Text(l10n.disablingRecommended),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.continueLabel)),
        ],
      ),
    );
    if (confirmed == true) {
      if (!mounted) return;
      apply((w) {
        final cats = {...w.blockedCategories}..removeAll(kRecommendedCategories);
        return w.copyWith(blockedCategories: cats.toList());
      });
    }
  }

  Widget _buildWebFilter() {
    final l10n = context.l10n;
    final wf = _draft.webFilter;
    void update(WebFilterRule Function(WebFilterRule) f) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: f(wf), appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, updatedAt: _draft.updatedAt));

    List<String> splitDomains(String text) =>
        text.split(',').map((d) => d.trim()).where((d) => d.isNotEmpty).toList();

    // Recommended categories first, then any legacy extras still editable.
    final categories = [...kRecommendedCategories, for (final c in _kCategories) if (!kRecommendedCategories.contains(c)) c];

    return ListView(
      key: const ValueKey('webFilterList'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        SwitchListTile(
          title: Text(l10n.recommendedProtection),
          subtitle: Text(l10n.recommendedProtectionSubtitle),
          value: _recommendedOn,
          onChanged: (v) => _toggleRecommended(v, update),
        ),
        const Divider(height: AppSpace.xl),
        Text(l10n.blockedCategories, style: Theme.of(context).textTheme.titleMedium),
        for (final c in categories)
          CheckboxListTile(
            key: ValueKey('category-$c'),
            dense: true,
            title: Text(l10n.webCategory(c)),
            value: wf.blockedCategories.contains(c),
            onChanged: (v) => update((w) {
              final cats = {...w.blockedCategories};
              v == true ? cats.add(c) : cats.remove(c);
              return w.copyWith(blockedCategories: cats.toList());
            }),
          ),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: _allowedDomains,
          decoration: InputDecoration(labelText: l10n.allowedDomainsLabel, border: const OutlineInputBorder()),
          onChanged: (v) => update((w) => w.copyWith(allowedDomains: splitDomains(v))),
        ),
        const SizedBox(height: AppSpace.md),
        TextField(
          controller: _blockedDomains,
          decoration: InputDecoration(labelText: l10n.blockedDomainsLabel, border: const OutlineInputBorder()),
          onChanged: (v) => update((w) => w.copyWith(blockedDomains: splitDomains(v))),
        ),
        SwitchListTile(
          title: Text(l10n.enforceSafeSearch),
          value: wf.safeSearchEnforced,
          onChanged: (v) => update((w) => w.copyWith(safeSearchEnforced: v)),
        ),
        const SizedBox(height: AppSpace.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.youtubeRestrictedMode, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.youtubeRestrictedDesc,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpace.sm),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'strict', label: Text(l10n.strict)),
                  ButtonSegment(value: 'moderate', label: Text(l10n.moderate)),
                  ButtonSegment(value: 'off', label: Text(l10n.off)),
                ],
                selected: {wf.youtubeRestrictedMode},
                onSelectionChanged: (sel) => update((w) => w.copyWith(youtubeRestrictedMode: sel.first)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Apps tab ----

  Widget _buildApps() {
    final l10n = context.l10n;
    void update(List<AppRule> rules) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: rules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, updatedAt: _draft.updatedAt));

    void updateAlwaysAllowed(List<String> apps) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: apps, updatedAt: _draft.updatedAt));

    return ListView(
      key: const ValueKey('appsRulesList'),
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        // Feature #9: apps that stay open during bedtime, school time,
        // pause and routines.
        Text(l10n.alwaysAllowed, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        Text(
          l10n.alwaysAllowedDesc,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpace.sm),
        if (_draft.alwaysAllowedApps.isEmpty)
          Text(l10n.noAlwaysAllowedApps)
        else
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              for (final pkg in _draft.alwaysAllowedApps)
                InputChip(
                  label: Text(pkg),
                  onDeleted: () => updateAlwaysAllowed([..._draft.alwaysAllowedApps]..remove(pkg)),
                ),
            ],
          ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: Text(l10n.addApp),
          onPressed: () async {
            final pkg = await showDialog<String>(context: context, builder: (_) => const _AddAlwaysAllowedDialog());
            if (pkg != null && !_draft.alwaysAllowedApps.contains(pkg)) {
              updateAlwaysAllowed([..._draft.alwaysAllowedApps, pkg]);
            }
          },
        ),
        const Divider(height: AppSpace.xxl),
        for (var i = 0; i < _draft.appRules.length; i++)
          _AppRuleTile(
            key: ValueKey(_draft.appRules[i].packageId),
            rule: _draft.appRules[i],
            onChanged: (r) => update([..._draft.appRules]..[i] = r),
            onRemove: () => update([..._draft.appRules]..removeAt(i)),
          ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton.icon(
          key: const ValueKey('pickInstalledApp'),
          icon: const Icon(Icons.apps),
          label: Text(l10n.chooseInstalledApp),
          onPressed: () async {
            final rule = await showDialog<AppRule>(
              context: context,
              builder: (_) => _InstalledAppsPicker(
                childId: widget.childId,
                existingPackageIds: {for (final r in _draft.appRules) r.packageId},
              ),
            );
            if (rule != null && !_draft.appRules.any((r) => r.packageId == rule.packageId)) {
              update([..._draft.appRules, rule]);
            }
          },
        ),
        const SizedBox(height: AppSpace.xs),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: Text(l10n.addAppRule),
          onPressed: () async {
            // Kept for an app the child has not reported yet: the typed path is
            // still the only way to rule on a package the agent has not seen.
            final rule = await showDialog<AppRule>(context: context, builder: (_) => const _AddAppRuleDialog());
            if (rule != null) update([..._draft.appRules, rule]);
          },
        ),
      ],
    );
  }

  // ---- Routines tab ----

  Widget _buildRoutines() {
    final l10n = context.l10n;
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
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        for (final r in _draft.routines)
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(r.name),
              subtitle: Text('${r.startTime}–${r.endTime} · ${r.days.map(l10n.weekdayShort).join(' ')}'),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => update([..._draft.routines]..remove(r))),
              onTap: () => edit(r),
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton.icon(icon: const Icon(Icons.add), label: Text(l10n.addRoutine), onPressed: () => edit()),
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
    final l10n = context.l10n;
    final r = widget.rule;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
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
            const SizedBox(height: AppSpace.sm),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'allow', label: Text(l10n.appActionAllow)),
                ButtonSegment(value: 'block', label: Text(l10n.appActionBlock)),
                ButtonSegment(value: 'time_limit', label: Text(l10n.appActionTimeLimit)),
              ],
              selected: {r.action},
              onSelectionChanged: (sel) => widget.onChanged(AppRule(packageId: r.packageId, appName: r.appName, action: sel.first, dailyLimitMinutes: r.dailyLimitMinutes)),
            ),
            if (r.action == 'time_limit') ...[
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l10n.limitPerDayLabel, border: const OutlineInputBorder(), isDense: true),
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
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.addAppRule),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _appName, decoration: InputDecoration(labelText: l10n.appNameLabel, border: const OutlineInputBorder())),
          const SizedBox(height: AppSpace.md),
          TextField(controller: _packageId, decoration: InputDecoration(labelText: l10n.packageIdLabel, border: const OutlineInputBorder())),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(
          onPressed: () {
            if (_packageId.text.trim().isEmpty) return;
            Navigator.of(context).pop(AppRule(packageId: _packageId.text.trim(), appName: _appName.text.trim().isEmpty ? _packageId.text.trim() : _appName.text.trim(), action: 'allow'));
          },
          child: Text(l10n.add),
        ),
      ],
    );
  }
}

/// Roadmap 3.4: pick an app the child actually has instead of typing a package id.
///
/// Reads [installedAppsProvider] (the child's devices, unioned). Search matches
/// the label or the package id; system apps are hidden by default because a
/// typical phone reports dozens of OEM entries before the apps a parent cares
/// about. An app that already has a rule is shown disabled with a check mark,
/// so the picker can never create a duplicate `AppRule`.
class _InstalledAppsPicker extends ConsumerStatefulWidget {
  final String childId;
  final Set<String> existingPackageIds;

  const _InstalledAppsPicker({required this.childId, required this.existingPackageIds});

  @override
  ConsumerState<_InstalledAppsPicker> createState() => _InstalledAppsPickerState();
}

class _InstalledAppsPickerState extends ConsumerState<_InstalledAppsPicker> {
  final _search = TextEditingController();
  String _query = '';
  bool _showSystem = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final report = ref.watch(installedAppsProvider(widget.childId));
    return Dialog(
      key: const ValueKey('installedAppsPicker'),
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(l10n.installedAppsTitle, style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                    key: const ValueKey('installedAppsClose'),
                    icon: const Icon(Icons.close),
                    tooltip: l10n.close,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('installedAppsSearch'),
                controller: _search,
                decoration: InputDecoration(
                  labelText: l10n.searchApps,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: AppSpace.sm),
              FilterChip(
                key: const ValueKey('installedAppsSystemFilter'),
                label: Text(l10n.showSystemApps),
                selected: _showSystem,
                onSelected: (v) => setState(() => _showSystem = v),
              ),
              const SizedBox(height: AppSpace.xs),
              Flexible(
                child: report.when(
                  loading: () => const Center(child: Padding(padding: EdgeInsets.all(AppSpace.xl), child: CircularProgressIndicator())),
                  error: (e, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l10n.installedAppsLoadFailed('$e'), textAlign: TextAlign.center),
                        TextButton(
                          onPressed: () {
                            // The apps provider awaits familyProvider; invalidate both or the
                            // retry re-awaits the same cached family error.
                            ref.invalidate(familyProvider);
                            ref.invalidate(installedAppsProvider(widget.childId));
                          },
                          child: Text(l10n.retry),
                        ),
                      ],
                    ),
                  ),
                  data: _buildList,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(InstalledAppsReport report) {
    final l10n = context.l10n;
    if (report.apps.isEmpty) {
      return ListView(
        key: const ValueKey('installedAppsEmpty'),
        shrinkWrap: true,
        children: [
          Text(l10n.installedAppsEmpty, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.xs),
          Text(l10n.installedAppsEmptyHint, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }
    final query = _query.trim().toLowerCase();
    final filtered = [
      for (final app in report.apps)
        if ((_showSystem || !app.isSystem) &&
            (query.isEmpty || app.label.toLowerCase().contains(query) || app.packageId.toLowerCase().contains(query)))
          app,
    ];
    if (filtered.isEmpty) {
      return ListView(
        key: const ValueKey('installedAppsNoMatch'),
        shrinkWrap: true,
        children: [Text(l10n.installedAppsNoMatch)],
      );
    }
    return ListView.builder(
      key: const ValueKey('installedAppsList'),
      shrinkWrap: true,
      itemCount: filtered.length + (report.truncated ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == filtered.length) {
          return Padding(
            padding: const EdgeInsets.all(AppSpace.sm),
            child: Text(l10n.installedAppsTruncated(report.apps.length), style: Theme.of(context).textTheme.bodySmall),
          );
        }
        final app = filtered[index];
        final ruled = widget.existingPackageIds.contains(app.packageId);
        return ListTile(
          key: ValueKey('installedApp-${app.packageId}'),
          enabled: !ruled,
          leading: Icon(app.isSystem ? Icons.settings_applications : Icons.apps),
          title: Text(app.label),
          subtitle: Text(app.packageId),
          trailing: ruled
              ? Icon(Icons.check_circle, semanticLabel: l10n.alreadyRuled)
              : const Icon(Icons.add),
          onTap: ruled
              ? null
              : () => Navigator.of(context).pop(
                    AppRule(packageId: app.packageId, appName: app.label, action: 'allow'),
                  ),
        );
      },
    );
  }
}

/// Feature #9 dialog: collects just a package id for the always-allowed list.
class _AddAlwaysAllowedDialog extends StatefulWidget {  const _AddAlwaysAllowedDialog();

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
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.addAlwaysAllowedTitle),
      content: TextField(
        controller: _packageId,
        decoration: InputDecoration(labelText: l10n.packageIdLabel, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(
          onPressed: () {
            final pkg = _packageId.text.trim();
            if (pkg.isEmpty) return;
            Navigator.of(context).pop(pkg);
          },
          child: Text(l10n.add),
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
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.existing == null ? l10n.addRoutine : l10n.editRoutine),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: InputDecoration(labelText: l10n.nameLabel, border: const OutlineInputBorder())),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: () => _pick(true), child: Text(l10n.startTimeButton(formatTime(_start))))),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text(l10n.endTimeButton(formatTime(_end))))),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                for (var i = 1; i <= 7; i++)
                  FilterChip(
                    label: Text(l10n.weekdayShort(i)),
                    selected: _days.contains(i),
                    onSelected: (sel) => setState(() => sel ? _days.add(i) : _days.remove(i)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            TextField(controller: _blocked, decoration: InputDecoration(labelText: l10n.blockedAppsLabel, border: const OutlineInputBorder())),
            const SizedBox(height: AppSpace.md),
            TextField(controller: _allowed, decoration: InputDecoration(labelText: l10n.allowedAppsLabel, border: const OutlineInputBorder())),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
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
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
