package com.familyshield.agent.enforcement

/**
 * One `block_bypass` alert per app per [floorMs], whatever raised it: a PiP or split-screen window that
 * stayed up (#443, [BlockRaisePolicy]) or a call that kept going (#444, [CallBlockPolicy]). The service
 * shares one instance between the two, so the parent is not paged twice for the same app (#449 review).
 */
class BypassAlertFloor(private val floorMs: Long = DEFAULT_FLOOR_MS) {
    private val lastReportMs = HashMap<String, Long>()

    /** True, and recorded, when [pkg] may be reported now. A backwards clock does not suppress forever. */
    fun tryReport(pkg: String, nowMs: Long): Boolean {
        val last = lastReportMs[pkg]
        if (last != null && nowMs - last in 0 until floorMs) return false
        lastReportMs[pkg] = nowMs
        return true
    }

    companion object {
        /** One bypass alert per app per ten minutes. */
        const val DEFAULT_FLOOR_MS: Long = 10 * 60_000L
    }
}
