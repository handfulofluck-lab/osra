package com.familyshield.agent.commands

import java.util.concurrent.atomic.AtomicInteger

/**
 * Issue #241: how many instances of a screen are visible, expressed as a count rather than a flag.
 *
 * `LockActivity` used to keep a single `isShowing` boolean, set in `onStart` and cleared in `onStop`.
 * If a visible instance finishes and a new one starts **before** the old one's `onStop`, the old
 * `onStop` clears the flag while the new screen is up — and a later `unlock` would ack `not_showing`
 * and leave that screen in place. Counting started instances cannot be misread that way.
 *
 * Pure and Android-free so the JVM can hold the rule: the Activity cannot be instantiated in this
 * suite, and the interleaving that matters is exactly the one a single instance cannot show.
 */
class VisibleScreens {

    private val started = AtomicInteger(0)

    /** True while at least one instance is between `onStart` and `onStop`. */
    val isShowing: Boolean
        get() = started.get() > 0

    /** Number of instances currently started; exposed for tests and diagnostics. */
    val startedCount: Int
        get() = started.get().coerceAtLeast(0)

    fun started() {
        started.incrementAndGet()
    }

    fun stopped() {
        // Defensive decrement: an unmatched stop (a platform quirk or a test) must not go negative
        // and make isShowing lie in the other direction.
        started.updateAndGet { current -> if (current > 0) current - 1 else 0 }
    }
}
