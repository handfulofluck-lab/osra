import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/digits.dart';
import '../../api/models.dart';
import '../../core/localized_list.dart';
import '../../l10n/l10n.dart';

import '../../api/permission_errors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import 'rules_behind_banner.dart';
import 'app_display.dart';
import 'app_picker.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../../widgets/layout_helpers.dart';

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
/// Issue #172 / ADR-0035: the payment surfaces the decision names. The list is a *suggestion* for the
/// shortcut, not a policy: nothing here is exempt from bedtime, and the parent confirms the package name
/// in the dialog before it becomes an always-allowed app.
const List<String> walletSuggestions = <String>[
  'com.samsung.android.spay',
  'com.google.android.apps.walletnfcrel',
  'com.samsung.android.samsungpay.gear',
];

/// #505: the screen-time sliders' range, in minutes. The API accepts more than the slider shows (up to
/// a day), so a value stored by another client can sit outside it.
const double kLimitSliderMin = 15;
const double kLimitSliderMax = 600;

/// #505: where the slider's thumb sits for a stored limit. `Slider` throws for a value outside
/// `[min, max]`, which took the whole editor down for a child with 1440 stored, so the thumb is clamped.
/// Only the thumb: the title and label keep showing the stored value, and the draft keeps it until the
/// parent moves the slider, so saving another rule never rewrites the limit.
double limitSliderPosition(int minutes) => minutes.toDouble().clamp(kLimitSliderMin, kLimitSliderMax);

class RulesEditorScreen extends ConsumerStatefulWidget {
  final String childId;
  final int initialTab;
  const RulesEditorScreen({super.key, required this.childId, this.initialTab = 0});

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

  /// U33 (#868): the child's display name, for the picker's subtitle; null until the overview loads.
  String? get _childName {
    final overview = ref.watch(familyProvider).valueOrNull;
    if (overview == null) return null;
    for (final child in overview.children) {
      if (child.id == widget.childId) return child.displayName;
    }
    return null;
  }

  /// U33 (#868): reported package id → the app the phone described, for the chips and rows that render
  /// a choice the parent already made. A package the phone no longer reports is absent from this map and
  /// its chip falls back to the id — the only place an id can still surface, and only for what is saved.
  /// Codex's #872 finding: a missing id is *confirmed absent* only when a report exists. Before any
  /// device reports, the honest state is "pending" and the Bureaus' second line says so.
  bool get _reportKnown => _reportIsComplete(ref, widget.childId);

  Map<String, InstalledApp> get _appIndex {
    final report = ref.watch(installedAppsProvider(widget.childId)).valueOrNull;
    return {
      for (final app in report?.apps ?? const <InstalledApp>[])
        app.packageId: app,
    };
  }

  // #872 condition 2, Claude's data shape (05:16Z): the name comes from the installed-apps report at
  // display time; when nothing reports the id, the Bureaus' line and a "?" avatar replace it. The id is
  // never shown to a parent — that was the finding.
  String _nameOf(Map<String, InstalledApp> apps, String packageId) =>
      appDisplayName(context, apps, packageId, reportKnown: _reportKnown);

  Widget _chipIcon(Map<String, InstalledApp> apps, String packageId) =>
      appDisplayAvatar(apps, packageId);

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
      // Issue #475: the PUT bumped `rulesVersion` on the server, and the banner compares that number with
      // what the phone applied. Without this the family snapshot still carries the pre-save version, so
      // right after Save `applied == rules` and the line the parent just earned never appears — which is
      // exactly the "I changed it, why is Meet still blocked?" moment it exists for.
      ref.invalidate(familyProvider);
      // #876: the save queues a `rules_updated` command, so every delivery list on this child is stale from
      // this moment. The family snapshot already carries the devices, so refresh each one's history — the
      // list used to change only after leaving the screen and coming back.
      final savedDevices = ref.read(familyProvider).valueOrNull?.devicesFor(widget.childId) ?? const <Device>[];
      for (final device in savedDevices) {
        ref.invalidate(deviceCommandHistoryProvider(device.id));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.rulesSaved)));
      }
    } on DioException catch (e) {
      // Issue #437: a rule write can be refused for consent (`428`); anything else maps cleanly.
      setState(() => _error = friendlyErrorText(
            l10n,
            e,
            () => l10n.saveFailed,
          ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(context: context, initialTime: initial);

  Size _measureSaveLabel(BuildContext context, AppLocalizations l10n) {
    final painter = TextPainter(
      text: TextSpan(text: l10n.save, style: Theme.of(context).textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.size;
  }

  bool _titleFitsInAppBar(
    BuildContext context,
    AppLocalizations l10n,
    double toolbarHeight,
    double saveWidth,
  ) {
    final textScaler = MediaQuery.textScalerOf(context);
    final titleStyle = Theme.of(context).appBarTheme.titleTextStyle ??
        Theme.of(context).textTheme.titleLarge ??
        const TextStyle(fontSize: 22);
    final saveAllowance = saveWidth + AppSpace.xl * 2 + AppSpace.sm + AppSpace.lg;
    const leadingAllowance = kToolbarHeight + AppSpace.lg;
    final availableTitleWidth = math.max(0.0, MediaQuery.sizeOf(context).width - leadingAllowance - saveAllowance);
    if (availableTitleWidth <= 0) return false;
    final titlePainter = TextPainter(
      text: TextSpan(text: l10n.editRules, style: titleStyle),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      maxLines: 2,
    )..layout(maxWidth: availableTitleWidth);
    return !titlePainter.didExceedMaxLines && titlePainter.height <= toolbarHeight - AppSpace.sm;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.childId));
    ref.listen(rulesProvider(widget.childId), (_, next) => next.whenData(_applyLoaded));
    final textScaler = MediaQuery.textScalerOf(context);
    final saveSize = _measureSaveLabel(context, l10n);
    final expandedToolbarHeight = math.max(kToolbarHeight, textScaler.scale(kToolbarHeight + AppSpace.sm));
    final titleInAppBar = _titleFitsInAppBar(context, l10n, expandedToolbarHeight, saveSize.width);
    final collapsedToolbarHeight = math.max(kToolbarHeight, saveSize.height + AppSpace.lg).ceilToDouble();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: titleInAppBar ? expandedToolbarHeight : collapsedToolbarHeight,
        title: titleInAppBar ? Text(l10n.editRules, maxLines: 2, overflow: TextOverflow.ellipsis) : null,
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
        error: (e, _) => ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.rulesLoadFailed),
          onRetry: () => ref.invalidate(rulesProvider(widget.childId)),
        ),
        data: (ruleSet) {
          _applyLoaded(ruleSet);
          return _buildTabs(context, showHeading: !titleInAppBar);
        },
      ),
    );
  }

  Widget _pageHeading(BuildContext context, AppLocalizations l10n) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.xs),
        child: Semantics(
          header: true,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(l10n.editRules, style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
      );

  Widget _buildTabs(BuildContext context, {required bool showHeading}) {
    final l10n = context.l10n;
    if (_error != null) {
      return Column(
        children: [
          if (showHeading) _pageHeading(context, l10n),
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: () => setState(() => _error = null), child: Text(l10n.dismiss))],
          ),
          const Expanded(child: SizedBox()),
        ],
      );
    }
    // Issue #475: the child's phones report the rules version they have SAVED AND APPLIED, and this is the
    // screen where a parent changes the rules — so it is where "the phone hasn't picked this up yet" has to
    // appear. The child comes from the overview the app already loads (#475 review: no extra request).
    // The widget renders nothing when the child is current, so the column below is unconditional.
    return Column(
      children: [
        if (showHeading) _pageHeading(context, l10n),
        RulesBehindBanner(childId: widget.childId),
        Expanded(child: _editorBody(l10n)),
      ],
    );
  }

  Widget _editorBody(AppLocalizations l10n) {
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.clamp(0, 3),
      child: Column(
        children: [
          FadingScrollableTabBar(
            tabBar: TabBar(
              isScrollable: true,
              tabs: FadingScrollableTabBar.scaledTabs(context, [
                l10n.tabScreenTime,
                l10n.tabWebFilter,
                l10n.tabApps,
                l10n.tabRoutines,
              ]),
            ),
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
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: f(st), webFilter: _draft.webFilter, appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, appGroupRules: _draft.appGroupRules, updatedAt: _draft.updatedAt));

    Widget timeTile(String label, String value, ValueChanged<TimeOfDay> onPicked) => Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
          child: LabelValueRow(
            label: label,
            value: value,
            labelStyle: Theme.of(context).textTheme.bodyLarge,
            onValueTap: () async {
              final t = await _pickTime(parseTime(value, const TimeOfDay(hour: 12, minute: 0)));
              if (t != null) onPicked(t);
            },
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(l10n.dailyLimit(st.dailyLimitMinutes), style: Theme.of(context).textTheme.titleMedium),
        Slider(value: limitSliderPosition(st.dailyLimitMinutes), min: kLimitSliderMin, max: kLimitSliderMax, divisions: 39, label: l10n.minutesShort(st.dailyLimitMinutes), semanticFormatterCallback: (v) => l10n.minutesShort(v.round()), onChanged: (v) => update((s) => ScreenTimeRule(dailyLimitMinutes: v.round(), weekendLimitMinutes: s.weekendLimitMinutes, bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
        const SizedBox(height: AppSpace.sm),
        Text(l10n.weekendLimit(st.weekendLimitMinutes), style: Theme.of(context).textTheme.titleMedium),
        Slider(value: limitSliderPosition(st.weekendLimitMinutes), min: kLimitSliderMin, max: kLimitSliderMax, divisions: 39, label: l10n.minutesShort(st.weekendLimitMinutes), semanticFormatterCallback: (v) => l10n.minutesShort(v.round()), onChanged: (v) => update((s) => ScreenTimeRule(dailyLimitMinutes: s.dailyLimitMinutes, weekendLimitMinutes: v.round(), bedtimeStart: s.bedtimeStart, bedtimeEnd: s.bedtimeEnd, schoolStart: s.schoolStart, schoolEnd: s.schoolEnd, schoolDays: s.schoolDays))),
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
        scrollable: true,
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
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: f(wf), appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, appGroupRules: _draft.appGroupRules, updatedAt: _draft.updatedAt));

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
          onChanged: (v) => update((w) => w.copyWith(allowedDomains: splitLocalizedList(v, stripDirectionMarks: true))),
        ),
        const SizedBox(height: AppSpace.md),
        TextField(
          controller: _blockedDomains,
          decoration: InputDecoration(labelText: l10n.blockedDomainsLabel, border: const OutlineInputBorder()),
          onChanged: (v) => update((w) => w.copyWith(blockedDomains: splitLocalizedList(v, stripDirectionMarks: true))),
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
    final names = _appIndex;
    // ADR-0037 decision 3: on an iPhone a blocked app id is hidden, not shielded; the rows say so.
    final childHasIphone = ref.watch(familyProvider).valueOrNull?.devices
            .any((d) => d.childId == widget.childId && d.platform == 'ios') ??
        false;
    final childHasAndroid = ref.watch(familyProvider).valueOrNull?.devices
            .any((d) => d.childId == widget.childId && d.platform == 'android') ??
        false;
    void update(List<AppRule> rules) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: rules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, appGroupRules: _draft.appGroupRules, updatedAt: _draft.updatedAt));

    void updateAlwaysAllowed(List<String> apps) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: _draft.appRules, routines: _draft.routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: apps, appGroupRules: _draft.appGroupRules, updatedAt: _draft.updatedAt));

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
              // U33 (#868): the chip carries the app's name and icon, never the package id the parent
              // would have had to type. An id whose app the phone no longer reports falls back to the id.
              for (final pkg in _draft.alwaysAllowedApps)
                if (names.containsKey(pkg))
                  InputChip(
                    avatar: _chipIcon(names, pkg),
                    label: Text(_nameOf(names, pkg)),
                    onDeleted: () => updateAlwaysAllowed([..._draft.alwaysAllowedApps]..remove(pkg)),
                  )
                else
                  // Codex's AR 320/200 % frames (#872): `InputChip` constrains its label to one line's
                  // height (`chip.dart`, `maxHeight: contentSize`), so the Bureaus' fallback sentence was
                  // cut mid-phrase even with `softWrap: true`. The one case whose label is a sentence gets
                  // a chip that grows with it — two lines in Arabic, three in English in the dialog; a
                  // real name keeps the Material chip unchanged.
                  _FallbackChip(
                    avatar: _chipIcon(names, pkg),
                    label: _nameOf(names, pkg),
                    tooltip: appRemoveLabel(context, reportKnown: _reportKnown),
                    onDeleted: () => updateAlwaysAllowed([..._draft.alwaysAllowedApps]..remove(pkg)),
                  ),
            ],
          ),
        const SizedBox(height: AppSpace.sm),
        // #172 / ADR-0035: payment surfaces stay blocked at bedtime, and this is where a family that
        // needs one fixes it. The sentence and the shortcut sit together on purpose — the decision is
        // only defensible if the way out of it is one tap away.
        // #643: Samsung Pay and Google Wallet are Android package ids. Hidden only when the child has NO
        // Android device — a mixed child (an iPhone and a tablet) must keep it for the tablet.
        if (childHasAndroid || !childHasIphone)
          Text(
            l10n.bedtimeBlocksPayments,
            key: const ValueKey('bedtime-blocks-payments'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: Text(l10n.addApp),
          onPressed: () async {
            final chosen = await showAppPicker(
              context,
              childId: widget.childId,
              childName: _childName,
              selected: {..._draft.alwaysAllowedApps},
              disabled: {
                for (final pkg in _draft.alwaysAllowedApps) pkg: l10n.alreadyRuled,
              },
            );
            if (chosen == null) return;
            updateAlwaysAllowed([
              ..._draft.alwaysAllowedApps,
              for (final app in chosen)
                if (!_draft.alwaysAllowedApps.contains(app.packageId)) app.packageId,
            ]);
          },
        ),
        const SizedBox(height: AppSpace.xs),
        TextButton.icon(
          key: const ValueKey('add-payment-app'),
          icon: const Icon(Icons.credit_card),
          label: Text(l10n.addPaymentApp),
          onPressed: () async {
            // #172 / U33: the shortcut opens the same picker with the wallet apps the phone actually
            // reports at the top of the list, so the choice is still made from real, named apps.
            var pinned = walletSuggestions;
            try {
              final installed = await ref.read(installedAppsProvider(widget.childId).future);
              final available = installed.apps.map((a) => a.packageId).toSet();
              final onPhone = [
                for (final pkg in walletSuggestions)
                  if (available.contains(pkg)) pkg,
              ];
              if (onPhone.isNotEmpty) pinned = onPhone;
            } catch (_) {
              // A phone that has not reported, or an offline read: the full suggestion order stays.
            }
            if (!mounted) return;
            final chosen = await showAppPicker(
              context,
              childId: widget.childId,
              childName: _childName,
              selected: {..._draft.alwaysAllowedApps},
              pinnedFirst: pinned,
              disabled: {
                for (final pkg in _draft.alwaysAllowedApps) pkg: l10n.alreadyRuled,
              },
            );
            if (chosen == null) return;
            updateAlwaysAllowed([
              ..._draft.alwaysAllowedApps,
              for (final app in chosen)
                if (!_draft.alwaysAllowedApps.contains(app.packageId)) app.packageId,
            ]);
          },
        ),
        const Divider(height: AppSpace.xxl),
        for (var i = 0; i < _draft.appRules.length; i++)
          _AppRuleTile(
            key: ValueKey(_draft.appRules[i].packageId),
            rule: _draft.appRules[i],
            app: names[_draft.appRules[i].packageId],
            reportKnown: _reportKnown,
            childHasIphone: childHasIphone,
            onChanged: (r) => update([..._draft.appRules]..[i] = r),
            onRemove: () => update([..._draft.appRules]..removeAt(i)),
          ),
        const SizedBox(height: AppSpace.sm),
        // #643: iOS never reports an app list, so the picker is a dead end for an iPhone-only child. A
        // mixed child keeps it for the Android device, and the sentence explains the iPhone path beside it.
        if (childHasIphone)
          Padding(
            key: const ValueKey('iosAppsExplained'),
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Text(l10n.appGroupsBody, style: Theme.of(context).textTheme.bodyMedium),
          ),
        // U33 (#868): the only way to add a rule is the picker — the package-id dialog is gone, because
        // an app the phone has not reported is not one a parent can meaningfully rule on yet.
        if (childHasAndroid || !childHasIphone)
          OutlinedButton.icon(
            key: const ValueKey('pickInstalledApp'),
            icon: const Icon(Icons.apps),
            label: Text(l10n.chooseInstalledApp),
            onPressed: () async {
              final chosen = await showAppPicker(
                context,
                childId: widget.childId,
                childName: _childName,
                disabled: {
                  for (final rule in _draft.appRules)
                    rule.packageId: rule.action == 'time_limit'
                        ? l10n.dailyLimit(rule.dailyLimitMinutes ?? 0)
                        : rule.action == 'block'
                            ? l10n.blocked
                            : l10n.alreadyRuled,
                },
              );
              if (chosen == null || chosen.isEmpty) return;
              update([
                ..._draft.appRules,
                for (final app in chosen)
                  if (!_draft.appRules.any((r) => r.packageId == app.packageId))
                    AppRule(packageId: app.packageId, appName: app.label, action: 'allow'),
              ]);
            },
          ),
      ],
    );
  }

  // ---- Routines tab ----

  Widget _buildRoutines() {
    final l10n = context.l10n;
    void update(List<Routine> routines) =>
        setState(() => _draft = RuleSet(id: _draft.id, childId: _draft.childId, screenTime: _draft.screenTime, webFilter: _draft.webFilter, appRules: _draft.appRules, routines: routines, socialMonitoring: _draft.socialMonitoring, contactAllowlist: _draft.contactAllowlist, alwaysAllowedApps: _draft.alwaysAllowedApps, appGroupRules: _draft.appGroupRules, updatedAt: _draft.updatedAt));

    Future<void> edit([Routine? existing]) async {
      final result = await showDialog<Routine>(
        context: context,
        builder: (_) => _RoutineDialog(existing: existing, childId: widget.childId),
      );
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

  /// U33 (#868): the app as the phone described it (icon, name). Null for a rule saved before the
  /// picker existed and whose app the phone no longer reports; the row then draws a letter avatar from
  /// the stored name, so no row ever shows a package id.
  final InstalledApp? app;

  final ValueChanged<AppRule> onChanged;
  final VoidCallback onRemove;
  final bool childHasIphone;

  /// Whether a device has reported its app list at all — Codex's #872 split: without one, a missing name
  /// is pending, not "no longer installed".
  final bool reportKnown;
  const _AppRuleTile({super.key, required this.rule, required this.onChanged, required this.onRemove, this.app, this.childHasIphone = false, this.reportKnown = true});

  @override
  State<_AppRuleTile> createState() => _AppRuleTileState();
}

/// Whether the child's inventory is **complete**: at least one device, every device has reported, and no
/// report is truncated.
///
/// Antigravity's #872 finding 3: the old check asked only the merged report's `reportedAt`, so a truncated
/// list or a second phone that had not checked in yet still counted as "a report exists" — and an app
/// missing from that partial list was labelled «App no longer installed», which is a claim about the child's
/// phone that a partial list cannot support.
bool _reportIsComplete(WidgetRef ref, String childId) {
  final groups = ref.watch(installedAppsByDeviceProvider(childId)).valueOrNull;
  if (groups == null || groups.isEmpty) return false;
  return groups.every((g) => g.report.reportedAt != null && !g.report.truncated);
}

/// True when a stored `appName` is a name a parent would recognise — not blank, not the package id.
bool _hasRealName(String appName, String packageId) {
  final name = appName.trim();
  return name.isNotEmpty && name != packageId;
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
                // #872 condition 2: a rule whose app nothing reports any more names itself with the
                // Bureaus' line and a "?" avatar — the package id is not a name, and it was the finding.
                appDisplayAvatar(
                  {if (widget.app != null) r.packageId: widget.app!},
                  r.packageId,
                  size: 28,
                  savedName: r.appName,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    appDisplayName(
                      context,
                      {if (widget.app != null) r.packageId: widget.app!},
                      r.packageId,
                      savedName: r.appName,
                      reportKnown: widget.reportKnown,
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  // Antigravity's #872 finding 2: a rule with a real saved name shows that name, so its
                  // remove action must not announce "Name not available yet". Only a row without a name
                  // carries the state's label.
                  tooltip: widget.app != null || _hasRealName(r.appName, r.packageId)
                      ? null
                      : appRemoveLabel(context, reportKnown: widget.reportKnown),
                  onPressed: widget.onRemove,
                ),
              ],
            ),
            // U33 (#868): the row names the app and shows its icon; the package id is not shown.
            const SizedBox(height: AppSpace.xs),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'allow', label: Text(l10n.appActionAllow)),
                ButtonSegment(value: 'block', label: Text(l10n.appActionBlock)),
                ButtonSegment(value: 'time_limit', label: Text(l10n.appActionTimeLimit)),
              ],
              selected: {r.action},
              onSelectionChanged: (sel) => widget.onChanged(AppRule(packageId: r.packageId, appName: r.appName, action: sel.first, dailyLimitMinutes: r.dailyLimitMinutes)),
            ),
            if (r.action == 'block' && widget.childHasIphone) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.appRuleHiddenOnIphone,
                key: ValueKey('hiddenOnIphone-${r.packageId}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (r.action == 'time_limit') ...[
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l10n.limitPerDayLabel, border: const OutlineInputBorder(), isDense: true),
                onChanged: (v) => widget.onChanged(AppRule(packageId: r.packageId, appName: r.appName, action: r.action, dailyLimitMinutes: int.tryParse(normalizeDigits(v)))),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Create/edit dialog for a Routine (name, window, weekday chips, app picks).
///
/// U33 (#868): the app lists are chosen from the picker and shown as chips. No comma-separated field
/// and no package id a parent would have to know — a routine's apps are the child's own reported apps.
class _RoutineDialog extends ConsumerStatefulWidget {
  final Routine? existing;
  final String childId;
  const _RoutineDialog({this.existing, required this.childId});

  @override
  ConsumerState<_RoutineDialog> createState() => _RoutineDialogState();
}

class _RoutineDialogState extends ConsumerState<_RoutineDialog> {
  /// The same split as the editor: no report yet is "pending", a report without the id is "gone".
  bool get _reportKnown => _reportIsComplete(ref, widget.childId);

  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final Set<String> _blocked = {...?widget.existing?.blockedApps};
  late final Set<String> _allowed = {...?widget.existing?.allowedApps};
  late TimeOfDay _start = parseTime(widget.existing?.startTime ?? '17:00', const TimeOfDay(hour: 17, minute: 0));
  late TimeOfDay _end = parseTime(widget.existing?.endTime ?? '19:00', const TimeOfDay(hour: 19, minute: 0));
  late Set<int> _days = {...?widget.existing?.days};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final t = await showTimePicker(context: context, initialTime: isStart ? _start : _end);
    if (t != null) setState(() => isStart ? _start = t : _end = t);
  }

  /// One routine list. [other] holds the ids in the sibling list: an app in both would be blocked and
  /// allowed at once, so the picker greys those out instead of letting a parent create the conflict.
  Future<void> _choose({required bool blockedList}) async {
    final l10n = context.l10n;
    final current = blockedList ? _blocked : _allowed;
    final other = blockedList ? _allowed : _blocked;
    final chosen = await showAppPicker(
      context,
      childId: widget.childId,
      selected: {...current},
      disabled: {for (final id in other) id: l10n.alreadyRuled},
    );
    if (chosen == null) return;
    setState(() {
      current
        ..clear()
        ..addAll([for (final app in chosen) app.packageId]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final report = ref.watch(installedAppsProvider(widget.childId)).valueOrNull;
    final apps = {
      for (final app in report?.apps ?? const <InstalledApp>[]) app.packageId: app,
    };
    return AlertDialog(
      scrollable: true,
      title: Text(widget.existing == null ? l10n.addRoutine : l10n.editRoutine),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _name, decoration: InputDecoration(labelText: l10n.nameLabel, border: const OutlineInputBorder())),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              OutlinedButton(onPressed: () => _pick(true), child: Text(l10n.startTimeButton(formatTime(_start)))),
              OutlinedButton(onPressed: () => _pick(false), child: Text(l10n.endTimeButton(formatTime(_end)))),
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
          _RoutineAppsField(
            keyPrefix: 'routineBlocked',
            title: l10n.blocked,
            packageIds: _blocked,
            reportKnown: _reportKnown,
            apps: apps,
            onPick: () => _choose(blockedList: true),
            onRemove: (id) => setState(() => _blocked.remove(id)),
          ),
          const SizedBox(height: AppSpace.md),
          _RoutineAppsField(
            keyPrefix: 'routineAllowed',
            title: l10n.alwaysAllowed,
            packageIds: _allowed,
            reportKnown: _reportKnown,
            apps: apps,
            onPick: () => _choose(blockedList: false),
            onRemove: (id) => setState(() => _allowed.remove(id)),
          ),
        ],
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
              blockedApps: _blocked.toList()..sort(),
              allowedApps: _allowed.toList()..sort(),
            ));
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// One app list in the routine dialog: the chosen apps as icon chips, and the button that opens the
/// picker. An id whose app the phone no longer reports keeps the id as its chip label (a saved value
/// that still has to be removable); nothing here ever *asks* for one.
class _RoutineAppsField extends StatelessWidget {
  final String keyPrefix;
  final String title;
  final Set<String> packageIds;
  final bool reportKnown;
  final Map<String, InstalledApp> apps;
  final VoidCallback onPick;
  final ValueChanged<String> onRemove;

  const _RoutineAppsField({
    required this.keyPrefix,
    required this.title,
    required this.packageIds,
    required this.reportKnown,
    required this.apps,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        if (packageIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                for (final id in packageIds)
                  if (apps.containsKey(id))
                    InputChip(
                      key: ValueKey('$keyPrefix-$id'),
                      avatar: appDisplayAvatar(apps, id),
                      label: Text(appDisplayName(context, apps, id, reportKnown: reportKnown)),
                      onDeleted: () => onRemove(id),
                    )
                  else
                    _FallbackChip(
                      key: ValueKey('$keyPrefix-$id'),
                      avatar: appDisplayAvatar(apps, id),
                      label: appDisplayName(context, apps, id, reportKnown: reportKnown),
                      tooltip: appRemoveLabel(context, reportKnown: reportKnown),
                      onDeleted: () => onRemove(id),
                    ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: ValueKey('$keyPrefix-pick'),
            icon: const Icon(Icons.apps),
            label: Text(l10n.chooseInstalledApp),
            onPressed: onPick,
          ),
        ),
      ],
    );
  }
}

/// A chip for a name that is a **sentence**: the Bureaus' pending / no-longer-installed line.
///
/// `InputChip` cannot carry one. Its label is laid out with `maxHeight: contentSize`
/// (`material/chip.dart`), which is a single line, and the label's default `softWrap: false` fades the
/// rest — so at AR 320 / 200 % «تطبيق لم يعد مثبّتًا» was cut mid-phrase. Codex's frames for #872 show
/// it on the Always-allowed list and inside the routine dialog. This keeps the chip's shape and the
/// remove control (with the Bureaus' remove label as its tooltip) and lets the label take two lines.
class _FallbackChip extends StatelessWidget {
  const _FallbackChip({
    super.key,
    required this.avatar,
    required this.label,
    required this.tooltip,
    required this.onDeleted,
  });

  final Widget avatar;
  final String label;
  final String tooltip;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Material(
      color: tokens.surfaceVariant,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.sm, AppSpace.xs, 0, AppSpace.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(width: AppSpace.xs),
            Flexible(
              // No `maxLines` and no ellipsis: Codex measured the English label needing **three**
              // lines inside the routine dialog at 320 px / 200 %, so a two-line cap only moved the cut
              // to a different screen. The sentence is short; letting it take what it needs is the only
              // setting that cannot hide part of it.
              child: Text(
                label,
                softWrap: true,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: tooltip,
              onPressed: onDeleted,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
