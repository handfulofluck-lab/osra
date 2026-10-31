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
class RulesBehindBanner extends ConsumerWidget {
  const RulesBehindBanner({super.key, required this.childId});

  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final child = ref.watch(familyProvider).valueOrNull?.children.where((c) => c.id == childId).firstOrNull;
    if (child == null || !rulesAreBehind(child)) return const SizedBox.shrink();
    return MaterialBanner(
      key: const ValueKey('rules-behind-banner'),
      content: Text(context.l10n.rulesBehindHint),
      leading: const Icon(Icons.sync_problem_outlined),
      actions: const [SizedBox.shrink()],
    );
  }
}
