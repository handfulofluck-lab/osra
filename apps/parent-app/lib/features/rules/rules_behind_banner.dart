import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';
import 'rules_freshness.dart';

/// Issue #475, generalised: "the phone hasn't picked this change up yet", as one widget.
///
/// The sentence belongs wherever a parent **changes rules**, not only on the rule editor. It reads the same
/// family overview every screen already loads ([familyProvider]), so a screen that shows it pays no extra
/// request — and a screen that forgets to refresh that provider after a save shows nothing at exactly the
/// moment it is earned, which is the #501 review finding.
///
/// Renders nothing — a zero-height [SizedBox] — when the child is unknown or current, so a screen can place
/// it unconditionally at the top of a column.
///
/// **When it clears** (#865): the server pushes `rules_applied` the moment the family's last reporting
/// device catches up, and [applyRealtimeMessage] refreshes the snapshot on it. For a dropped socket, the
/// widget also re-reads the snapshot when the app comes back to the foreground — no poll, and no state of
/// its own beyond the observer.
class RulesBehindBanner extends ConsumerStatefulWidget {
  const RulesBehindBanner({super.key, required this.childId});

  final String childId;

  @override
  ConsumerState<RulesBehindBanner> createState() => _RulesBehindBannerState();
}

class _RulesBehindBannerState extends ConsumerState<RulesBehindBanner> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The backstop for a report the socket missed while the app was in the background: the next look at
    // the screen re-reads the one number the line depends on.
    ref.invalidate(familyProvider);
  }

  @override
  Widget build(BuildContext context) {
    final child = ref.watch(familyProvider).valueOrNull?.children.where((c) => c.id == widget.childId).firstOrNull;
    if (child == null || !rulesAreBehind(child)) return const SizedBox.shrink();
    return MaterialBanner(
      key: const ValueKey('rules-behind-banner'),
      content: Text(context.l10n.rulesBehindHint),
      leading: const Icon(Icons.sync_problem_outlined),
      actions: const [SizedBox.shrink()],
    );
  }
}
