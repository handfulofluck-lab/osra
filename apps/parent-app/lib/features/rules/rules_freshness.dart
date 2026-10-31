import '../../api/models.dart';

/// Issue #475: is the child's phone still running rules from before the parent's last change?
///
/// The parent app can answer this from two numbers it already has: the ruleset's version (bumped by the
/// server on every ruleset write) and the version the phone reports it has **saved and applied**.
///
/// **Three states, and only one of them warns:**
/// - both known and `applied < rules` → the phone is behind;
/// - `applied == rules` → the phone has the change;
/// - `applied` is null → the phone has never reported, which is not the same as being behind. A warning
///   here would fire on every fresh install and teach the parent to ignore it.
///
/// `applied > rules` cannot happen through the server (it only stores a version it issued), and is treated
/// as "not behind": a number we did not issue is a bug, and a warning built on it would be a second one.
bool rulesAreBehind(Child child) {
  final rules = child.rulesVersion;
  final applied = child.appliedRulesVersion;
  if (rules == null || applied == null) return false;
  return applied < rules;
}
