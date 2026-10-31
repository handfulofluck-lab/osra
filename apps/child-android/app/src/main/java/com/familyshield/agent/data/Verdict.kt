package com.familyshield.agent.data

/**
 * Issue #473: one decision **and the window that produced it**, from one walk of the order.
 *
 * **Why this exists rather than two calls.** The first version of this feature asked the engine for the
 * decision and then asked again for the reason (`windowFor`). Two problems, both found in review:
 * a pause or a blocklisted app blocks *before* any window is consulted, so the second call named a window
 * the decision had never reached; and a rules sync between the two calls could name a window that was not
 * the one that blocked. A verdict is the same walk answering both questions.
 *
 * [reason] is null whenever the block did not come from a window — a pause, an explicit `block`, a
 * `time_limit`, the blocklist, or the fail-closed path with no cached rules. The block screen shows the
 * window only when one is named, because naming a window promises the app opens when it ends.
 */
data class Verdict(
    val decision: RuleRepository.Decision,
    val reason: WindowReason? = null,
)
