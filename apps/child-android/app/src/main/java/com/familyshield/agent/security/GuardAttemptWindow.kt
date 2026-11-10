package com.familyshield.agent.security

/**
 * Issue #227: repeated attempts to open a protection-removal screen are one alert per window, with a
 * count. Five attempts 10 s apart used to be five critical pages; the parent now sees one row that
 * says five.
 *
 * The window is identified by its persisted start time and nothing else. It is deliberately **not**
 * keyed on the guard overlay becoming visible or the removal screen closing again: the child drives
 * both transitions, so a visibility-keyed window would reset on every retry and page every time.
 * [WINDOW_MS] matches the five minutes in the issue.
 *
 * The rule lives here, free of Android types, because the service and the worker cannot run in a JVM
 * test. The count is persisted before the POST so a failed POST cannot lose an attempt: the next
 * attempt carries the cumulative number.
 */
object GuardAttemptWindow {

    /** One alert window. The first attempt opens it; later attempts increment [count]. */
    const val WINDOW_MS: Long = 5 * 60_000L

    /** osra-security#6 (10 Nov): at most this many distinct screens are kept per window. */
    const val MAX_SCREENS: Int = 8

    /**
     * [screens] are the distinct protection screens tried in this window, first seen first, as lower-case
     * [TamperScreen] names (e.g. `deactivate_admin`, `space_setup`). A repeat in an open window used to keep only the count, so a parent
     * who had seen "device admin" never learned a second space was being set up in the same five minutes.
     */
    data class State(val windowStartMs: Long, val count: Int, val screens: List<String> = emptyList())

    /** [state] is the state to persist; [opensWindow] is true when this attempt starts a new alert. */
    data class Attempt(val state: State, val opensWindow: Boolean)

    /**
     * Folds one attempt at [nowMs] into [state], or opens a window when there is none, the previous
     * one is at least [WINDOW_MS] old, or the clock went backwards past its start.
     *
     * An attempt exactly at `windowStart + WINDOW_MS` belongs to the **new** window, so a five-minute
     * window covers `[start, start + WINDOW_MS)`. A backwards clock cannot reset the window (which
     * would page for each attempt); it keeps incrementing the current one.
     */
    fun record(state: State?, nowMs: Long, screen: String? = null): Attempt {
        val first = listOfNotNull(screen?.takeIf { it.isNotBlank() })
        if (state == null || nowMs < state.windowStartMs || nowMs - state.windowStartMs >= WINDOW_MS) {
            return Attempt(State(windowStartMs = nowMs, count = 1, screens = first), opensWindow = true)
        }
        val screens = (state.screens + first).distinct().take(MAX_SCREENS)
        return Attempt(state.copy(count = state.count + 1, screens = screens), opensWindow = false)
    }

    /**
     * The alert body for an open window. One attempt keeps the specific [detail]; more name every distinct
     * screen tried, so a new kind of attempt inside the window is not lost behind the count.
     */
    fun body(count: Int, screens: List<String>, detail: String): String {
        if (count <= 1) return detail
        val tried = screens.joinToString(", ") { label(it) }
        val which = if (tried.isEmpty()) "" else " Screens tried: $tried."
        return "$count attempts were made to open a protection-removal screen on this device in 5 minutes.$which " +
            "The PIN was asked for each time."
    }

    /** What the parent reads for each [TamperScreen], by its lower-case name; an unknown name reads as itself. */
    fun label(screen: String): String = when (screen) {
        "deactivate_admin" -> "device admin"
        "uninstall" -> "uninstall"
        "app_info" -> "app info"
        "private_dns" -> "private DNS"
        "space_setup" -> "second space setup"
        else -> screen.replace('_', ' ')
    }

    /** Saved form of [State.screens]: one line, comma-separated (the names never contain a comma). */
    fun encodeScreens(screens: List<String>): String = screens.joinToString(",")

    /** Inverse of [encodeScreens]; null or empty (state saved before the list existed) is no screens. */
    fun decodeScreens(saved: String?): List<String> = saved.orEmpty().split(',').filter { it.isNotBlank() }
}
