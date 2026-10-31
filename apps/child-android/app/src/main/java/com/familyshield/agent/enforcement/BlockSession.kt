package com.familyshield.agent.enforcement

import com.familyshield.agent.data.WindowReason

/**
 * The block currently on screen (issue #217). [BlockActivity] is `launchMode="singleTask"`, so a second
 * block reuses the instance; this holder is what `onNewIntent` updates. Reading the intent once in
 * `onCreate` left the previous package in both the label and the actions, so "Request access" would ask
 * the parent to unblock the **previous** app and `clearDebounce` cleared the wrong package.
 */
internal data class BlockRequest(
    val packageId: String = "",
    val reason: String = BlockActivity.REASON_BLOCKED,
    /**
     * Issue #473: the window that fired, when one did. Part of the request rather than of the screen's
     * local state, because `BlockActivity` is `singleTask` — a second block reuses the instance, and a
     * stale window from the previous app would be the #217 bug again.
     */
    val window: WindowReason? = null,
) {
    val timeLimit: Boolean
        get() = reason == BlockActivity.REASON_TIME_LIMIT
}

/**
 * A Compose-free state holder, so the intent-to-screen transition can be pinned by a JVM test without
 * Robolectric. [BlockActivity] mirrors every [apply] into Compose state through [onChanged].
 *
 * [labelOf] resolves the user-facing app name; when it returns null or blank (the package was removed
 * while the screen was up, or the OS refused the lookup) the package id is shown instead, never a blank
 * line.
 */
internal class BlockSession(
    private val labelOf: (String) -> String?,
    private val onChanged: (BlockRequest, String) -> Unit = { _, _ -> },
) {
    var request: BlockRequest = BlockRequest()
        private set

    var appLabel: String = ""
        private set

    /** Applies the extras of the intent that is currently on screen, replacing any previous block. */
    fun apply(packageId: String?, reason: String?, window: WindowReason? = null) {
        request = BlockRequest(packageId.orEmpty(), reason ?: BlockActivity.REASON_BLOCKED, window)
        appLabel = if (request.packageId.isBlank()) {
            ""
        } else {
            labelOf(request.packageId)?.takeIf { it.isNotBlank() } ?: request.packageId
        }
        onChanged(request, appLabel)
    }

    /** The package "Request access" must ask about — always the one currently on screen. */
    fun requestAccessPackage(): String = request.packageId

    /** The package whose debounce "Exit to Home screen" must clear, or null when there is none. */
    fun clearDebouncePackage(): String? = request.packageId.takeIf { it.isNotBlank() }
}
