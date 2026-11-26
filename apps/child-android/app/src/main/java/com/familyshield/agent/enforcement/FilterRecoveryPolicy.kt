package com.familyshield.agent.enforcement

/** Keep secondary app windows covered while allowing the foreground to remain usable for recovery or calls. */
internal object FilterRecoveryPolicy {
    data class Presentation(val blockedForeground: String?, val coveredWindows: Set<WindowBounds>)

    fun presentation(
        snapshot: WindowSnapshot,
        foreground: String?,
        isExempt: (String) -> Boolean,
    ): Presentation {
        val candidates = EssentialPackages.blockCandidates(foreground, snapshot.windows)
            .filterNot(isExempt)
            .toSet()
        val blockedForeground = foreground?.takeIf { it in candidates }
        if (snapshot.layout == WindowLayout.NORMAL) {
            return Presentation(blockedForeground, emptySet())
        }
        val covered = snapshot.windows.asSequence()
            .filter { it.packageName in candidates && (it.inPictureInPicture || it.packageName != foreground) }
            .mapNotNull { it.bounds?.takeUnless(WindowBounds::isEmpty) }
            .toSet()
        return Presentation(blockedForeground, covered)
    }
}
