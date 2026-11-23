import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../rules/app_picker.dart' show AppIconBadge;

/// Karim, 23 Nov: "blocking and unblocking apps is a stupid flow and lacks any app icons".
///
/// The Apps tab lists every app on the child's phone, with its own icon and name (never a package id),
/// and one switch per app: on is allowed, off is blocked. A change saves at once and offers Undo.
/// Tapping a row opens the choices for that app: allow, block, or a daily time limit.
/// Apps the phone needs for calls and safety show "Always allowed" and have no switch.
class ChildAppsList extends ConsumerStatefulWidget {
  final String childId;
  final RuleSet ruleSet;
  final InstalledAppsReport report;

  /// Lines under a row for an app a bedtime, school or routine window is blocking right now (#456).
  final Widget? Function(String packageId)? windowNote;

  /// Opens the curated insight sheet for an app (Feature #12).
  final void Function(String packageId)? onInsight;

  const ChildAppsList({
    super.key,
    required this.childId,
    required this.ruleSet,
    required this.report,
    this.windowNote,
    this.onInsight,
  });

  @override
  ConsumerState<ChildAppsList> createState() => _ChildAppsListState();
}

enum AppsFilter { all, blocked, limited }

/// "30 min", or "1 h" / "2 h" for whole hours.
String formatAppLimit(AppLocalizations l10n, int minutes) =>
    minutes >= 60 && minutes % 60 == 0 ? l10n.hoursShort(minutes ~/ 60) : l10n.minutesShort(minutes);

/// Daily limits offered in an app's sheet, in minutes.
const kAppLimitChoices = [15, 30, 60, 120];

class _ChildAppsListState extends ConsumerState<ChildAppsList> {
  final _search = TextEditingController();
  AppsFilter _filter = AppsFilter.all;

  /// Rules the parent just changed, shown at once while the save is in flight (and kept if it fails
  /// until the snackbar says so). Cleared when the saved rules come back.
  List<AppRule>? _optimistic;
  bool _saving = false;

  @override
  void didUpdateWidget(ChildAppsList old) {
    super.didUpdateWidget(old);
    if (!identical(old.ruleSet, widget.ruleSet) && !_saving) _optimistic = null;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AppRule> get _rules => _optimistic ?? widget.ruleSet.appRules;

  AppRule? _ruleFor(String packageId) => _rules.where((r) => r.packageId == packageId).firstOrNull;

  /// Replace (or remove, for allow) the rule for one app and save it. `allow` removes the rule, so an
  /// allowed app has no row in the rule set; that is what "allowed" means on the phone.
  Future<void> _setAction(InstalledApp app, String action, {int? minutes}) => _save(
        app,
        action == 'allow'
            ? null
            : AppRule(packageId: app.packageId, appName: app.label, action: action, dailyLimitMinutes: minutes),
      );

  /// Saves [rule] as this app's whole rule (null removes it). Undo puts back the **exact** previous rule
  /// object, so an explicit "Always allowed" (`action: allow`) comes back as itself, not as "no rule"
  /// (Codex on #1008: that would quietly put the app back under bedtime and school hours).
  ///
  /// One save at a time (Codex, osra-security#71): while a save is in flight every rule-edit entry point
  /// (switch, row, sheet, Undo) is inert, so a second edit can't be built on rules the server hasn't
  /// confirmed. Interaction resumes when the save succeeds or fails.
  Future<void> _save(InstalledApp app, AppRule? rule, {bool offerUndo = true}) async {
    if (_saving) return;
    final l10n = context.l10n;
    final before = _rules;
    final next = [
      for (final r in before)
        if (r.packageId != app.packageId) r,
      if (rule != null) rule,
    ];
    setState(() {
      _optimistic = next;
      _saving = true;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).raw.patch(
        '/v1/rules/${widget.childId}',
        data: {
          'appRules': [for (final r in next) r.toJson()]
        },
      );
      ref.invalidate(rulesProvider(widget.childId));
      // Issue #475: the family snapshot carries the rules version the "applied on the phone" line compares.
      ref.invalidate(familyProvider);
      if (!mounted) return;
      final text = switch (rule?.action) {
        'block' => l10n.appBlockedNamedSnack(app.label),
        'time_limit' => l10n.appLimitSnack(app.label, formatAppLimit(l10n, rule?.dailyLimitMinutes ?? 0)),
        _ => l10n.appAllowedSnack(app.label),
      };
      final previous = before.where((r) => r.packageId == app.packageId).firstOrNull;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(text),
        action: offerUndo
            ? SnackBarAction(
                label: l10n.undo,
                onPressed: () => _save(app, previous, offerUndo: false),
              )
            : null,
      ));
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _optimistic = before);
      messenger.showSnackBar(SnackBar(content: Text(friendlyErrorText(l10n, e, () => l10n.saveFailed))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSheet(InstalledApp app) async {
    final l10n = context.l10n;
    final rule = _ruleFor(app.packageId);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        Widget choice(String key, IconData icon, String label, bool selected, VoidCallback onTap) => ListTile(
              key: ValueKey(key),
              leading: Icon(icon),
              title: Text(label),
              trailing: selected ? Icon(Icons.check, color: theme.colorScheme.primary) : null,
              onTap: () {
                Navigator.of(ctx).pop();
                onTap();
              },
            );
        final action = rule?.action ?? 'allow';
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: AppIconBadge(app: app, size: 40),
                  title: Text(app.label, style: theme.textTheme.titleMedium),
                ),
                const Divider(height: 1),
                choice('appSheetAllow', Icons.check_circle_outline, l10n.appActionAllow, action == 'allow',
                    () => _setAction(app, 'allow')),
                choice('appSheetBlock', Icons.block, l10n.appActionBlock, action == 'block',
                    () => _setAction(app, 'block')),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.sm, AppSpace.lg, 0),
                  child: Text(l10n.appActionTimeLimit, style: theme.textTheme.titleSmall),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
                  child: Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.sm,
                    children: [
                      for (final m in kAppLimitChoices)
                        ChoiceChip(
                          key: ValueKey('appSheetLimit-$m'),
                          label: Text(formatAppLimit(l10n, m)),
                          selected: action == 'time_limit' && rule?.dailyLimitMinutes == m,
                          onSelected: (_) {
                            Navigator.of(ctx).pop();
                            _setAction(app, 'time_limit', minutes: m);
                          },
                        ),
                    ],
                  ),
                ),
                if (widget.onInsight != null)
                  ListTile(
                    key: const ValueKey('appSheetInsight'),
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.appAboutThisApp),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      widget.onInsight!(app.packageId);
                    },
                  ),
                const SizedBox(height: AppSpace.sm),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();

    // Every reported app, plus any app that has a rule but is no longer reported (so a block stays visible).
    final byPackage = {for (final a in widget.report.apps) a.packageId: a};
    for (final r in _rules) {
      byPackage.putIfAbsent(
        r.packageId,
        () => InstalledApp(
            packageId: r.packageId, label: r.appName == r.packageId ? l10n.appNoLongerInstalled : r.appName),
      );
    }
    final apps = byPackage.values.toList()..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    final blockedCount = _rules.where((r) => r.action == 'block').length;
    final limitedCount = _rules.where((r) => r.action == 'time_limit').length;
    final shown = [
      for (final a in apps)
        if ((query.isEmpty || a.label.toLowerCase().contains(query)) &&
            switch (_filter) {
              AppsFilter.all => true,
              AppsFilter.blocked => _ruleFor(a.packageId)?.action == 'block',
              AppsFilter.limited => _ruleFor(a.packageId)?.action == 'time_limit',
            })
          a,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('appsSearch'),
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.searchApps,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          children: [
            ChoiceChip(
              key: const ValueKey('appsFilterAll'),
              label: Text(l10n.appsFilterAll(apps.length)),
              selected: _filter == AppsFilter.all,
              onSelected: (_) => setState(() => _filter = AppsFilter.all),
            ),
            ChoiceChip(
              key: const ValueKey('appsFilterBlocked'),
              label: Text(l10n.appsFilterBlocked(blockedCount)),
              selected: _filter == AppsFilter.blocked,
              onSelected: (_) => setState(() => _filter = AppsFilter.blocked),
            ),
            ChoiceChip(
              key: const ValueKey('appsFilterLimited'),
              label: Text(l10n.appsFilterLimited(limitedCount)),
              selected: _filter == AppsFilter.limited,
              onSelected: (_) => setState(() => _filter = AppsFilter.limited),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
            child: Center(child: Text(l10n.appsNoMatch, key: const ValueKey('appsNoMatch'))),
          ),
        for (final app in shown) _row(context, app, theme),
      ],
    );
  }

  Widget _row(BuildContext context, InstalledApp app, ThemeData theme) {
    final l10n = context.l10n;
    final rule = _ruleFor(app.packageId);
    final essential = app.essential == true;
    final action = rule?.action ?? 'allow';
    final (String state, Color? color) = essential
        ? (l10n.alwaysAllowed, theme.colorScheme.onSurfaceVariant)
        : switch (action) {
            'block' => (l10n.appStateBlocked, theme.colorScheme.error),
            'time_limit' => (
                l10n.appStateLimit(formatAppLimit(l10n, rule?.dailyLimitMinutes ?? 0)),
                context.tokens.severityWarningText
              ),
            _ => (l10n.appStateAllowed, theme.colorScheme.onSurfaceVariant),
          };
    final note = widget.windowNote?.call(app.packageId);
    return ListTile(
      key: ValueKey('appRow-${app.packageId}'),
      contentPadding: EdgeInsets.zero,
      leading: Opacity(opacity: action == 'block' ? 0.45 : 1, child: AppIconBadge(app: app, size: 40)),
      title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(state,
              key: ValueKey('appState-${app.packageId}'), style: theme.textTheme.bodySmall?.copyWith(color: color)),
          if (note != null) note,
        ],
      ),
      trailing: essential
          ? Icon(Icons.lock_outline, size: 20, color: theme.colorScheme.onSurfaceVariant)
          : Switch(
              key: ValueKey('appSwitch-${app.packageId}'),
              value: action != 'block',
              onChanged: _saving ? null : (allowed) => _setAction(app, allowed ? 'allow' : 'block'),
            ),
      enabled: !_saving || essential,
      onTap: essential || _saving ? null : () => _openSheet(app),
    );
  }
}
