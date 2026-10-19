package com.familyshield.agent.enforcement

/**
 * Issue #175: one application window the accessibility service can see. The active-window-only
 * decision from #171 never judged an app that was **visible but not active** — a PiP video over
 * Home, or the other half of a split screen — so the block and lock overlays never came up for it.
 *
 * [inPictureInPicture] comes from `AccessibilityWindowInfo.isInPictureInPictureMode` (API 26, which
 * is this app's `minSdk`); there is no separate "split screen" flag in the accessibility API, so a
 * second visible application window is the split-screen signal (see [WindowSnapshot.layout]).
 */
data class VisibleWindow(
    val packageName: String?,
    val inPictureInPicture: Boolean = false,
)

/** The arrangement of the application windows visible in one accessibility event. */
enum class WindowLayout {
    /** One application window: the ordinary case this service was written for. */
    NORMAL,

    /** Two or more application windows side by side (or stacked); no PiP window. */
    SPLIT_SCREEN,

    /** At least one application window is in picture-in-picture. */
    PICTURE_IN_PICTURE,
}

/**
 * A snapshot of what the OS says is on screen, taken once per accessibility event.
 *
 * Issue #175: the snapshot is the input to both decisions — the block path judges every package in
 * [windows], and the lock path answers "is the overlay already covering this screen?" from the same
 * list. Taking it once per event keeps the binder traffic to one `windows` walk and one
 * `rootInActiveWindow` read (both recycled by the service).
 */
data class WindowSnapshot(
    /** Package of the active window, or null when the OS will not name it. */
    val activePackage: String?,
    val windows: List<VisibleWindow>,
) {
    /** Two different packages with a normal window is a split screen; a PiP window wins over both. */
    val layout: WindowLayout
        get() = when {
            windows.any { it.inPictureInPicture } -> WindowLayout.PICTURE_IN_PICTURE
            windows.filter { !it.inPictureInPicture && !it.packageName.isNullOrBlank() }
                .mapNotNull { it.packageName }
                .distinct()
                .size > 1 -> WindowLayout.SPLIT_SCREEN
            else -> WindowLayout.NORMAL
        }

    /**
     * Stable name for "the state the overlay was asked to cover". The retry budget resets when this
     * changes, so a child who reacts to the overlay (closes PiP, leaves split) gets a fresh attempt,
     * while a state the platform refuses to change cannot be retried forever.
     */
    val signature: String
        get() = buildList {
            if (!activePackage.isNullOrBlank()) add("active:$activePackage")
            addAll(
                windows
                    .filter { !it.packageName.isNullOrBlank() }
                    .map { "${it.packageName}:${if (it.inPictureInPicture) "pip" else "win"}" },
            )
        }.distinct().sorted().joinToString(",")
}
