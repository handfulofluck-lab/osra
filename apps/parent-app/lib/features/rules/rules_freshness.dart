import '../../api/models.dart';

/// Issue #475 & #1157: freshness state of a child's applied rules compared to the server's ruleset.
enum RulesFreshness {
  /// Current (`applied >= rules`), unpaired (no phone paired to apply rules yet), or older server (`rulesVersion == null`).
  current,

  /// A paired phone exists and the server has rules (`rulesVersion != null`), but no device has
  /// reported an applied rules version yet (`appliedRulesVersion == null`).
  waitingForFirstApply,

  /// Both versions are known and `appliedRulesVersion < rulesVersion`.
  behind,
}

/// Issue #475 & #1157: classify how fresh a child's applied rules are for the parent banner.
///
/// **Three outcomes:**
/// - `rulesVersion == null` → [RulesFreshness.current] (older server that does not send versions);
/// - `appliedRulesVersion == null` and [hasPairedDevice] → [RulesFreshness.waitingForFirstApply]
///   (paired phone has not applied its first rules version yet; unpaired children stay [RulesFreshness.current]);
/// - both known and `applied < rules` → [RulesFreshness.behind];
/// - both known and `applied >= rules` → [RulesFreshness.current] (`applied > rules` cannot come from the
///   server and is treated as not behind rather than raising a bogus warning).
RulesFreshness rulesFreshness(Child child, {required bool hasPairedDevice}) {
  final rules = child.rulesVersion;
  final applied = child.appliedRulesVersion;
  if (rules == null) return RulesFreshness.current;
  if (applied == null) {
    return hasPairedDevice ? RulesFreshness.waitingForFirstApply : RulesFreshness.current;
  }
  return applied < rules ? RulesFreshness.behind : RulesFreshness.current;
}

/// Issue #475: is the child's phone still running rules from before the parent's last change?
///
/// Only `applied != null && applied < rules` is "behind" — a phone that has never reported is
/// [RulesFreshness.waitingForFirstApply], not behind.
bool rulesAreBehind(Child child) =>
    rulesFreshness(child, hasPairedDevice: false) == RulesFreshness.behind;
