import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../l10n/l10n.dart';
import '../../widgets/error_retry_view.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../rules/app_picker.dart' show AppIconBadge;
import '../social/social_app_catalog.dart';
import '../social/social_screen.dart' show socialAppIcon;

/// Play decision 14 A (Karim, 2026-11-11) — **the parent chooses the monitored apps during setup.**
///
/// Before this step, message monitoring was on for every supported app unless a parent found the rules screen
/// later and turned one off. That is not a choice a data-safety form can describe as "optional", and the
/// Arabic consent card could not honestly say the parent opted in. So the choice is made here, with the
/// child's installed apps preselected and Select all available, and written with the same `socialMonitoring` map the rules and social
/// screens already edit — no new model, no second source of truth.
///
/// It is a self-contained step so the onboarding redesign (#557) can move it: one route, one file.
class SetupMonitoringScreen extends ConsumerStatefulWidget {
  /// The child being set up. Absent only if onboarding lost it, in which case the step is skipped.
  final String? childId;
  const SetupMonitoringScreen({super.key, this.childId});

  @override
  ConsumerState<SetupMonitoringScreen> createState() =>
      _SetupMonitoringScreenState();
}

class _SetupMonitoringScreenState extends ConsumerState<SetupMonitoringScreen> {
  late final Set<String> _selected = {
    if (widget.childId == null)
      for (final a in kSocialApps) a.appKey,
  };
  bool _selectionInitialized = false;
  bool _xChoiceInitialized = false;
  bool _saving = false;

  void _applyInstalled(InstalledAppsReport report) {
    if (_selectionInitialized) return;
    _selectionInitialized = true;
    _selected.addAll(installedSocialAppsByKey(report).keys);
  }

  void _applyRules(RuleSet ruleSet) {
    if (_xChoiceInitialized) return;
    if (!ruleSet.socialMonitoring.containsKey('twitter') &&
        !ruleSet.socialMonitoring.containsKey('x')) {
      return;
    }
    _xChoiceInitialized = true;
    if (socialMonitoringEnabled(ruleSet.socialMonitoring, 'twitter')) {
      _selected.add('twitter');
    } else {
      _selected.remove('twitter');
    }
  }

  void _setSelected(String appKey, bool selected) {
    setState(() {
      if (appKey == 'twitter') _xChoiceInitialized = true;
      if (selected) {
        _selected.add(appKey);
      } else {
        _selected.remove(appKey);
      }
    });
  }

  Widget _appTile(SocialAppInfo app, InstalledApp? installed) {
    final l10n = context.l10n;
    final selected = _selected.contains(app.appKey);
    return CheckboxListTile(
      key: ValueKey('setupMonitoring_${app.appKey}'),
      value: selected,
      horizontalTitleGap: AppSpace.sm,
      title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(app.appKey == 'youtube'
          ? l10n.socialCommentsAndChats
          : selected
              ? l10n.socialChecking
              : l10n.socialOff),
      secondary: installed == null
          ? Icon(socialAppIcon(app.appKey))
          : AppIconBadge(app: installed, size: 32),
      onChanged: _saving ? null : (on) => _setSelected(app.appKey, on == true),
    );
  }

  Widget _appList(InstalledAppsReport report) {
    final l10n = context.l10n;
    final installed = installedSocialAppsByKey(report);
    final present = sortedSocialApps(
        kSocialApps.where((app) => installed.containsKey(app.appKey)));
    final absent = sortedSocialApps(
        kSocialApps.where((app) => !installed.containsKey(app.appKey)));
    final child = ref
        .read(familyProvider)
        .valueOrNull
        ?.children
        .where((c) => c.id == widget.childId)
        .firstOrNull;
    return Column(
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: const ValueKey('setupMonitoringSelectAll'),
            onPressed: _saving
                ? null
                : () => setState(() {
                      _xChoiceInitialized = true;
                      _selected.addAll(kSocialApps.map((app) => app.appKey));
                    }),
            icon: const Icon(Icons.select_all),
            label: Text(l10n.selectAll),
          ),
        ),
        for (final app in present) _appTile(app, installed[app.appKey]),
        if (absent.isNotEmpty)
          ExpansionTile(
            key: const ValueKey('setupMonitoringNotInstalledGroup'),
            title: Text(l10n.socialNotOnChildPhone(
                context.localeName == 'ar'
                    ? '\u{2068}${child?.displayName ?? l10n.unknown}\u{2069}'
                    : child?.displayName ?? l10n.unknown,
                absent.length)),
            children: [for (final app in absent) _appTile(app, null)],
          ),
      ],
    );
  }

  Future<void> _finish() async {
    final l10n = context.l10n;
    final childId = widget.childId;
    // Nothing to write without a child: the step must not block onboarding on a state we cannot fix here.
    if (childId == null) {
      context.go('/setup/done');
      return;
    }
    setState(() => _saving = true);
    try {
      // **PATCH, and only this screen's key.** A PUT of a locally-built `RuleSet` would replace fields this
      // screen never read — for a child paired one screen ago `rulesProvider` is still loading, so the body
      // would carry `const RuleSet()` and wipe the server's defaults: 13 blocked web categories and the
      // 300-minute weekend limit (#587 review). The PATCH route merges server-side, so the parent's other
      // settings are untouched.
      await ref.read(apiClientProvider).raw.patch('/v1/rules/$childId', data: {
        // The server replaces the whole map, so every app this build knows is sent, ticked or not.
        'socialMonitoring': {
          for (final a in kSocialApps) a.appKey: _selected.contains(a.appKey)
        },
      });
      ref.invalidate(rulesProvider(childId));
      ref.invalidate(familyProvider);
      if (mounted) context.go('/setup/done');
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(l10n, e, () => l10n.saveFailed),
          onRetry: _finish,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final childId = widget.childId;
    final inventory =
        childId == null ? null : ref.watch(installedAppsProvider(childId));
    final rules = childId == null ? null : ref.watch(rulesProvider(childId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.setupMonitoringAppBarTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(l10n.setupMonitoringTitle,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpace.sm),
          Text(l10n.setupMonitoringIntro,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpace.sm),
          // The consent sentence: what monitoring means, in the numbers §5 of the data-safety answers states.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Text(l10n.setupMonitoringConsent,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          if (inventory == null)
            _appList(const InstalledAppsReport())
          else
            inventory.when(
              loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpace.lg),
                  child: Center(child: CircularProgressIndicator())),
              error: (e, _) => ErrorRetryView(
                message: friendlyErrorText(
                    l10n, e, () => l10n.installedAppsLoadFailed),
                onRetry: () => ref.invalidate(installedAppsProvider(childId!)),
              ),
              data: (report) {
                _applyInstalled(report);
                rules?.whenData(_applyRules);
                return _appList(report);
              },
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: FilledButton(
            key: const ValueKey('setupMonitoringContinue'),
            onPressed: _saving ? null : _finish,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.setupMonitoringContinue),
          ),
        ),
      ),
    );
  }
}
