import '../../api/models.dart';

/// Which rule is holding an app shut right now (#456).
enum WindowKind {
  /// `screenTime.schoolHours`, restricted to its configured days.
  school,

  /// `screenTime.bedtimeStart`–`bedtimeEnd`, every day.
  bedtime,

  /// A named routine's window, from `RuleSet.routines`.
  routine,
}

/// The window that is currently in force for one app, and when it ends.
class ActiveWindow {
  final WindowKind kind;

  /// The routine's own name for [WindowKind.routine]; null for the two screen-time windows, whose
  /// label is localised by the caller (`l10n.schoolHours` / `l10n.bedtime`).
  final String? routineName;

  /// The window's end as the rules carry it (`HH:mm`), so the sentence reads "until 15:00".
  final String endsAt;

  const ActiveWindow({required this.kind, required this.endsAt, this.routineName});

  @override
  bool operator ==(Object other) =>
      other is ActiveWindow &&
      other.kind == kind &&
      other.routineName == routineName &&
      other.endsAt == endsAt;

  @override
  int get hashCode => Object.hash(kind, routineName, endsAt);

  @override
  String toString() => 'ActiveWindow($kind, ${routineName ?? '-'}, until $endsAt)';
}

/// Issue #456: why a parent's screen says an app is openable but the phone refuses it.
///
/// **This mirrors the child agent's own order, and only the part the parent can know.** The agent's
/// `RuleEngine.evaluate` (`apps/child-android/.../data/RuleEngine.kt`) runs: always-allowed, pause,
/// routines, per-app rules, blocklist category, global time limit, bedtime, school hours. The parent
/// app has no usage counters, no blocklist pack and no paused/paired state, so this function answers
/// only the three questions that depend on the clock: is a **routine** holding this package, and — if
/// it has no per-app rule of its own — is it **bedtime** or **school hours**?
///
/// The two consequences a reader must not miss, because they are the agent's behaviour rather than a
/// simplification here:
///
/// 1. **An explicit per-app `allow` beats bedtime and school hours** (`RuleEngine.kt:64-74` returns
///    ALLOW before either window is read). So an app the parent set to *allowed* is never described
///    as blocked by school hours — only a routine can override it, and routine windows are evaluated
///    before per-app rules (`RuleEngine.kt:49-59`).
/// 2. **`time_limit` and `block` return null on purpose**: those are the app's own rule, not a
///    routine overriding an allowed one, and a time limit needs today's usage, which the parent app
///    does not have. Saying "blocked now by school hours" next to an app the parent blocked would be
///    a wrong reason, which is worse than no reason.
///
/// [now] is the wall clock of the device the rules apply to. The caller passes the parent's local
/// time today (see the note in the PR): a parent in another zone than the child would mis-read the
/// window, which is why the family timezone is the next step rather than a guess here.
ActiveWindow? activeWindowFor({
  required String packageId,
  required RuleSet rules,
  required DateTime now,
}) {
  // 0. Parent-mandated exemptions win over every window (`RuleEngine.kt:41`).
  if (rules.alwaysAllowedApps.contains(packageId)) return null;

  final day = now.weekday; // 1 = Monday … 7 = Sunday, same as Kotlin's DayOfWeek.value.
  final time = _minutesOfDay(now);

  // 1. Routine windows, in the agent's order: allow-list membership wins inside the same routine,
  //    an explicit blockedApps entry blocks, and a routine with an allow-list blocks everything it
  //    does not name. Anything else leaves the app untouched by that routine.
  for (final routine in rules.routines) {
    if (!routine.days.contains(day)) continue;
    if (!_inWindow(time, routine.startTime, routine.endTime)) continue;
    if (routine.allowedApps.contains(packageId)) continue;
    if (routine.blockedApps.contains(packageId)) {
      return ActiveWindow(kind: WindowKind.routine, routineName: routine.name, endsAt: routine.endTime);
    }
    if (routine.allowedApps.isNotEmpty) {
      return ActiveWindow(kind: WindowKind.routine, routineName: routine.name, endsAt: routine.endTime);
    }
  }

  // 2. The app's own rule: an `allow` short-circuits both screen-time windows, and `block` /
  //    `time_limit` are not "a routine overriding an allowed app".
  final appRule = rules.appRules.where((r) => r.packageId == packageId).firstOrNull;
  if (appRule != null) return null;

  // 3. Bedtime, every day — the agent reads it before school hours.
  if (_inWindow(time, rules.screenTime.bedtimeStart, rules.screenTime.bedtimeEnd)) {
    return ActiveWindow(kind: WindowKind.bedtime, endsAt: rules.screenTime.bedtimeEnd);
  }

  // 4. School hours, only on the configured days.
  if (rules.screenTime.schoolDays.contains(day) &&
      _inWindow(time, rules.screenTime.schoolStart, rules.screenTime.schoolEnd)) {
    return ActiveWindow(kind: WindowKind.school, endsAt: rules.screenTime.schoolEnd);
  }

  return null;
}

/// `RuleEngine.inWindow`: `[start, end)` when start ≤ end, and the overnight wrap `[start, 24h) ∪
/// [0, end)` when start > end. Equal times are an empty window, which `start ≤ end` gives for free
/// (`time >= s && time < s`), and a malformed time is not in any window.
bool _inWindow(int minutes, String start, String end) {
  final s = _parseHhMm(start);
  final e = _parseHhMm(end);
  if (s == null || e == null) return false;
  if (s <= e) return minutes >= s && minutes < e;
  return minutes >= s || minutes < e;
}

int _minutesOfDay(DateTime now) => now.hour * 60 + now.minute;

int? _parseHhMm(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}
