package com.familyshield.agent.data

/** Which rule is holding an app shut right now (issue #473). */
enum class WindowKind {
    /** A named routine's window, from `RuleSetDto.routines`. */
    ROUTINE,
    /** `screenTime.bedtimeStart`–`bedtimeEnd`, every day. */
    BEDTIME,
    /** `screenTime.schoolHours`, restricted to its configured days. */
    SCHOOL,
}

/**
 * Issue #473: the window that fired, what to call it, and when it ends.
 *
 * **Why the engine reports it rather than the screen guessing.** `BlockActivity` used to receive one of
 * two strings — `blocked` or `time_limit` — so a child kept in a Study routine and a child kept out of
 * school hours read exactly the same sentence. The ordering that decides *which* window fires lives in
 * `RuleEngine.evaluate`, and a second copy beside the UI is how the two would drift (#456's review made
 * the same argument for the parent app).
 *
 * [name] is the family's own routine name, so it is never localised. [endsAt] is the `HH:mm` the rules
 * carry, formatted by the screen in the device's locale conventions.
 *
 * **Only windows appear here.** A pause, an explicit `block`, a `time_limit` and the blocklist's
 * category protection are the app's own reason, not a window; [RuleEngine.windowFor] answers null for
 * each, and a null reason means the screen keeps its existing copy.
 */
data class WindowReason(
    val kind: WindowKind,
    val name: String?,
    val endsAt: String,
)
