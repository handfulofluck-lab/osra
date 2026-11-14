import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../social/social_screen.dart' show kSocialApps;

/// Play decision 14 A (Karim, 2026-11-11) — **the parent chooses the monitored apps during setup.**
///
/// Before this step, message monitoring was on for every supported app unless a parent found the rules screen
/// later and turned one off. That is not a choice a data-safety form can describe as "optional", and the
/// Arabic consent card could not honestly say the parent opted in. So the choice is made here, **all ticked**
/// (the product default is unchanged), and written with the same `socialMonitoring` map the rules and social
/// screens already edit — no new model, no second source of truth.
///
/// It is a self-contained step so the onboarding redesign (#557) can move it: one route, one file.
class SetupMonitoringScreen extends ConsumerStatefulWidget {
  /// The child being set up. Absent only if onboarding lost it, in which case the step is skipped.
  final String? childId;
  const SetupMonitoringScreen({super.key, this.childId});

  @override
  ConsumerState<SetupMonitoringScreen> createState() => _SetupMonitoringScreenState();
}

class _SetupMonitoringScreenState extends ConsumerState<SetupMonitoringScreen> {
  /// Every app ticked, which is what the product did before this screen existed.
  final Set<String> _selected = {for (final a in kSocialApps) a.appKey};
  bool _saving = false;

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
        'socialMonitoring': {for (final a in kSocialApps) a.appKey: _selected.contains(a.appKey)},
      });
      ref.invalidate(rulesProvider(childId));
      ref.invalidate(familyProvider);
      if (mounted) context.go('/setup/done');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.saveFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.setupMonitoringTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(l10n.setupMonitoringIntro, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpace.sm),
          // The consent sentence: what monitoring means, in the numbers §5 of the data-safety answers states.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Text(l10n.setupMonitoringConsent, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          for (final app in kSocialApps)
            CheckboxListTile(
              key: ValueKey('setupMonitoring_${app.appKey}'),
              value: _selected.contains(app.appKey),
              title: Text(app.label),
              onChanged: _saving
                  ? null
                  : (on) => setState(() {
                        if (on == true) {
                          _selected.add(app.appKey);
                        } else {
                          _selected.remove(app.appKey);
                        }
                      }),
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
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.setupMonitoringContinue),
          ),
        ),
      ),
    );
  }
}
