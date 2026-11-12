import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// Whether [rules] blocks [groupId]; the phone makes upper-case ids and the server may store either case.
bool appGroupBlocked(RuleSet rules, String groupId) =>
    rules.appGroupRules.any((r) => r.action == 'block' && r.groupId.toLowerCase() == groupId.toLowerCase());

/// The rule list after setting [groupId] to [blocked]: every other group's rule is kept as it is.
List<AppGroupRule> appGroupRulesWith(List<AppGroupRule> current, String groupId, bool blocked) => [
      for (final r in current)
        if (r.groupId.toLowerCase() != groupId.toLowerCase()) r,
      if (blocked) AppGroupRule(groupId: groupId),
    ];

/// ADR-0037 PR B3c: the app groups an iPhone reported (label and counts only), each with a Block switch that
/// writes `appGroupRules` (#580). The iPhone shields a blocked group together with the groups blocked on the
/// phone itself (#581), so this switch can add a block but never lift one set on the phone.
///
/// Renders nothing for a phone that reported no groups (every Android phone, and an iPhone before its first
/// group).
class AppGroupsSection extends ConsumerStatefulWidget {
  final Device device;
  const AppGroupsSection({super.key, required this.device});

  @override
  ConsumerState<AppGroupsSection> createState() => _AppGroupsSectionState();
}

class _AppGroupsSectionState extends ConsumerState<AppGroupsSection> {
  /// Groups whose switch is being saved, so a second tap waits for the first.
  final Set<String> _saving = {};

  Future<void> _set(String groupId, bool blocked) async {
    final childId = widget.device.childId;
    final messenger = ScaffoldMessenger.of(context);
    final failed = context.l10n.appGroupsSaveFailed;
    setState(() => _saving.add(groupId));
    try {
      final api = ref.read(apiClientProvider).raw;
      // Read the stored rules first, so another guardian's change to a different group is not overwritten.
      final res = await api.get('/v1/rules/$childId');
      final current = RuleSet.fromJson(Map<String, dynamic>.from(res.data as Map));
      final next = appGroupRulesWith(current.appGroupRules, groupId, blocked);
      await api.patch('/v1/rules/$childId', data: {
        'appGroupRules': [for (final r in next) r.toJson()],
      });
      ref.invalidate(rulesProvider(childId));
      ref.invalidate(familyProvider);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    } finally {
      if (mounted) setState(() => _saving.remove(groupId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.device.setup?.groups;
    if (groups == null || groups.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.device.childId)).valueOrNull;
    return Padding(
      key: const ValueKey('appGroupsSection'),
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.appGroupsTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.xxs),
          Text(l10n.appGroupsBody, style: Theme.of(context).textTheme.bodySmall),
          for (final g in groups)
            SwitchListTile(
              key: ValueKey('appGroup-${g.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(g.label),
              subtitle: Text(l10n.appGroupsCounts(g.apps, g.categories, g.sites)),
              secondary: Text(l10n.appGroupsBlock),
              value: rules != null && appGroupBlocked(rules, g.id),
              // Disabled until the rules are loaded, and while this group's change is being saved.
              onChanged: rules == null || _saving.contains(g.id) ? null : (v) => _set(g.id, v),
            ),
        ],
      ),
    );
  }
}
