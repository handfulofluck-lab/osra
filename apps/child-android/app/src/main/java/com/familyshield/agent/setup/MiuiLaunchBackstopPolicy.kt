package com.familyshield.agent.setup

import com.familyshield.agent.capabilities.CapabilitiesPolicy
import com.familyshield.agent.enforcement.RetryDecision
import com.familyshield.agent.enforcement.WindowBounds
import java.util.Locale

/** Which protection surface MIUI silently aborted when launching its full-screen Activity (#1236). */
enum class MiuiBackstopSurface {
    LOCK,
    BLOCK,
    GUARD;

    val wire: String
        get() = name.lowercase(Locale.US)

    companion object {
        fun fromWire(raw: String?): MiuiBackstopSurface = when (raw?.trim()?.lowercase(Locale.US)) {
            "block" -> BLOCK
            "guard" -> GUARD
            else -> LOCK
        }
    }
}

/** Pure backstop decision when a protection Activity fails to appear after retries exhaust (#1236). */
data class MiuiBackstopDecision(
    val showAccessibilityCover: Boolean,
    val alertParent: Boolean,
)

/**
 * Issue #1236 (after-test contingency, gated behind `ChildUxFlags.miuiLockBackstopEnabled`):
 * 1. When MIUI / HyperOS silently aborts background starts of `LockActivity`, `BlockActivity`, or
 *    `TamperGuardTaskActivity` even after setup (retry budget exhausted on a Xiaomi-family phone),
 *    OSRA raises a full-screen `TYPE_ACCESSIBILITY_OVERLAY` cover (which needs no `MIUIOP 10021`
 *    and cannot be blocked by MIUI background-popup restrictions) and sends ONE deduplicated parent
 *    alert per surface per UTC day.
 * 2. Reports Xiaomi's background pop-up permission as its own capability grant state
 *    (`miui_popup`: `granted`, `missing`, `confirmed_unverified`, or `not_applicable`) so the
 *    server and parent setup view distinguish an OS-verified grant from a parent-confirmed
 *    unreadable state.
 */
object MiuiLaunchBackstopPolicy {

    /**
     * Pure decision for Lock and Guard retry budgets (JVM-tested):
     * - Switch OFF or non-Xiaomi device: never activates the MIUI backstop.
     * - Switch ON + Xiaomi / Redmi / POCO:
     *   - [RetryDecision.ATTEMPT] -> normal Activity start still in flight; no backstop yet.
     *   - [RetryDecision.EXHAUSTED_ONCE] -> raise full-screen accessibility cover AND alert parent once.
     *   - [RetryDecision.EXHAUSTED] -> keep full-screen accessibility cover up silently (no duplicate alert).
     */
    fun decide(
        enabled: Boolean,
        manufacturer: String?,
        retryDecision: RetryDecision,
    ): MiuiBackstopDecision {
        if (!enabled || !MiuiBackgroundPopupPolicy.isXiaomiFamily(manufacturer)) {
            return MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false)
        }
        return when (retryDecision) {
            RetryDecision.ATTEMPT -> MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false)
            RetryDecision.EXHAUSTED_ONCE -> MiuiBackstopDecision(showAccessibilityCover = true, alertParent = true)
            RetryDecision.EXHAUSTED -> MiuiBackstopDecision(showAccessibilityCover = true, alertParent = false)
        }
    }

    /**
     * Pure decision for [com.familyshield.agent.enforcement.VisibleBlockStep], which surfaces
     * retry exhaustion via `step.reportBypass` once per episode.
     */
    fun decideBlockBypass(
        enabled: Boolean,
        manufacturer: String?,
        reportBypass: Boolean,
        alreadyCovering: Boolean,
    ): MiuiBackstopDecision {
        if (!enabled || !MiuiBackgroundPopupPolicy.isXiaomiFamily(manufacturer)) {
            return MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false)
        }
        return when {
            reportBypass -> MiuiBackstopDecision(showAccessibilityCover = true, alertParent = true)
            alreadyCovering -> MiuiBackstopDecision(showAccessibilityCover = true, alertParent = false)
            else -> MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false)
        }
    }

    /** Dedupe key capping MIUI launch-blocked alerts to at most one per surface per UTC day. */
    fun dedupeKey(deviceId: String?, surface: MiuiBackstopSurface, dayUtc: String): String? {
        val cleanId = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val cleanDay = dayUtc.trim().takeIf { it.isNotEmpty() } ?: return null
        return "miui_launch_blocked:$cleanId:${surface.wire}:$cleanDay"
    }

    /** Human-readable parent alert body for [surface]. */
    fun alertBody(surface: MiuiBackstopSurface): String {
        val surfaceName = when (surface) {
            MiuiBackstopSurface.LOCK -> "the lock screen"
            MiuiBackstopSurface.BLOCK -> "the app block screen"
            MiuiBackstopSurface.GUARD -> "the protection guard"
        }
        return "Xiaomi MIUI blocked OSRA from opening $surfaceName. OSRA raised a fallback cover — check \"Display pop-up windows while running in the background\" in MIUI Other permissions."
    }

    /**
     * Honest `capabilities.grants.miui_popup` wire state:
     * - Non-Xiaomi -> `not_applicable`
     * - Xiaomi `ALLOWED` -> `granted`
     * - Xiaomi `DENIED` -> `missing` (even if `parentConfirmed == true`)
     * - Xiaomi `UNREADABLE` + `parentConfirmed == true` -> `confirmed_unverified`
     * - Xiaomi `UNREADABLE` + `parentConfirmed == false` -> `missing`
     */
    fun miuiPopupWireState(
        manufacturer: String?,
        op10021Mode: Int?,
        op10020Mode: Int?,
        parentConfirmed: Boolean,
    ): String {
        if (!MiuiBackgroundPopupPolicy.isXiaomiFamily(manufacturer)) {
            return CapabilitiesPolicy.NOT_APPLICABLE
        }
        return when (MiuiBackgroundPopupPolicy.classifyState(manufacturer, op10021Mode, op10020Mode)) {
            MiuiPopupState.ALLOWED -> CapabilitiesPolicy.GRANTED
            MiuiPopupState.DENIED -> CapabilitiesPolicy.MISSING
            MiuiPopupState.UNREADABLE ->
                if (parentConfirmed) CapabilitiesPolicy.CONFIRMED_UNVERIFIED else CapabilitiesPolicy.MISSING
        }
    }

    /** Full-screen bounds helper for the accessibility overlay backstop. */
    fun fullScreenBounds(widthPx: Int, heightPx: Int): WindowBounds? {
        if (widthPx <= 0 || heightPx <= 0) return null
        return WindowBounds(left = 0, top = 0, right = widthPx, bottom = heightPx)
    }
}
