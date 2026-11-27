package com.familyshield.agent.enforcement

import com.familyshield.agent.commands.CommandOutcome
import com.familyshield.agent.commands.LockActivity

/**
 * Runtime feature switch for the `#1183` after-test Lock force-close / sign-out follow-up.
 *
 * Strictly default-off (`false`) until reviewed after the Saturday test, so Saturday Lock and
 * Pause behaviour and command ack payloads remain byte-for-byte unchanged.
 */
object LockForceCloseFlags {
    @Volatile
    var enabled: Boolean = false
}

/** Honest wire value for `detail.apps_closed` on a `lock` command ack (#1183). */
enum class AppsCloseOutcome(val wire: String) {
    /** Full build with `KILL_BACKGROUND_PROCESSES`: OS asked to kill non-exempt background processes. */
    BACKGROUND_KILLED("background_killed"),

    /** Play build, missing permission, or zero killable targets: non-exempt apps are covered only. */
    COVERED_ONLY("covered_only"),

    /** Non-lock mode (`pause` / `pause_internet`): closing apps never applies outside Lock. */
    SKIPPED_NOT_LOCK("skipped_not_lock"),
}

/** Honest wire value for `detail.session_ended` on a `lock` command ack (#1183). */
enum class SessionSignOutOutcome(val wire: String) {
    /** Consumer Android without Device Owner cannot sign a child out of other apps or the OS user. */
    UNSUPPORTED_ANDROID("unsupported_android"),

    /** Reserved strictly for managed Device Owner user-switch/logout when actually performed. */
    DEVICE_OWNER_CLEARED("device_owner_cleared"),
}

/** Pure execution plan for closing background apps under Lock (#1183). */
data class LockClosePlan(
    val shouldExecute: Boolean,
    val targetPackages: List<String>,
)

/**
 * Issue #1183 after-test follow-up (Karim 26 Nov 17:18 & 17:21 UAE):
 * - Applies **only to Lock** (`MODE_LOCKED`), **never** to Pause internet (`MODE_PAUSED_INTERNET`)
 *   or Pause device (`MODE_PAUSED`).
 * - Honest about Android OS limits without Device Owner:
 *   - Full build (`KILL_BACKGROUND_PROCESSES`): asks `ActivityManager.killBackgroundProcesses` for
 *     each non-essential, non-always-allowed package and reports `apps_closed = "background_killed"`
 *     (never falsely claiming `force_stopped`).
 *   - Play build (no `KILL_BACKGROUND_PROCESSES` permission, preserving ADR-0021): reports
 *     `apps_closed = "covered_only"`.
 *   - Both consumer builds report `session_ended = "unsupported_android"` (never falsely claiming
 *     third-party app or OS account sign-out).
 */
object LockForceClosePolicy {

    private val EMPTY_FACTS: PackageFacts = object : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = false
        override fun dialerRoleHolders(): Set<String> = emptySet()
    }

    /**
     * Computes which packages may have their background processes killed when [mode] activates.
     * Always empty when [enabled] is `false` or [mode] is not `MODE_LOCKED`.
     */
    fun plan(
        enabled: Boolean,
        mode: String?,
        installedPackages: Collection<String>,
        ownPackage: String,
        alwaysAllowedPackages: Set<String>,
        facts: PackageFacts = EMPTY_FACTS,
    ): LockClosePlan {
        if (!enabled || mode != LockActivity.MODE_LOCKED) {
            return LockClosePlan(shouldExecute = false, targetPackages = emptyList())
        }
        val homePackages = facts.homePackages()
        val targets = installedPackages.asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .filterNot { it == ownPackage }
            .filterNot { EssentialPackages.isEssential(it, facts) }
            .filterNot { pkg ->
                pkg in alwaysAllowedPackages && !LockEnforcementPolicy.isLockAllowlistDenied(pkg, homePackages)
            }
            .distinct()
            .sorted()
            .toList()
        return LockClosePlan(shouldExecute = true, targetPackages = targets)
    }

    /**
     * Whether active media playback from [pkg] should be paused while the device is locked (#1183).
     * Never pauses own package, essential packages, or legitimate always-allowed apps.
     */
    fun shouldPauseMediaUnderLock(
        enabled: Boolean,
        mode: String?,
        pkg: String?,
        ownPackage: String,
        alwaysAllowedPackages: Set<String>,
        facts: PackageFacts = EMPTY_FACTS,
    ): Boolean {
        if (!enabled || mode != LockActivity.MODE_LOCKED) return false
        val clean = pkg?.trim().orEmpty()
        if (clean.isEmpty() || clean == ownPackage) return false
        if (EssentialPackages.isEssential(clean, facts)) return false
        if (clean in alwaysAllowedPackages && !LockEnforcementPolicy.isLockAllowlistDenied(clean, facts.homePackages())) {
            return false
        }
        return true
    }

    /**
     * Honest ack detail additions for `lock` when [enabled] is `true`.
     * Returns an empty map when [enabled] is `false` or [mode] is not `MODE_LOCKED` so disabled
     * builds and non-lock commands keep their exact existing ack payload.
     */
    fun ackDetailAdditions(
        enabled: Boolean,
        mode: String?,
        hasKillPermission: Boolean,
        killedCount: Int,
        isDeviceOwner: Boolean = false,
        deviceOwnerSignedOut: Boolean = false,
    ): Map<String, String> {
        if (!enabled || mode != LockActivity.MODE_LOCKED) return emptyMap()
        val safeCount = if (hasKillPermission) killedCount.coerceAtLeast(0) else 0
        val appsClosed = if (hasKillPermission && safeCount > 0) {
            AppsCloseOutcome.BACKGROUND_KILLED
        } else {
            AppsCloseOutcome.COVERED_ONLY
        }
        val sessionEnded = if (isDeviceOwner && deviceOwnerSignedOut) {
            SessionSignOutOutcome.DEVICE_OWNER_CLEARED
        } else {
            SessionSignOutOutcome.UNSUPPORTED_ANDROID
        }
        return linkedMapOf(
            "apps_closed" to appsClosed.wire,
            "apps_closed_count" to safeCount.toString(),
            "session_ended" to sessionEnded.wire,
        )
    }

    /** Attaches [additions] only to [CommandOutcome.Applied]; never alters [CommandOutcome.Refused] or [CommandOutcome.Deferred]. */
    fun mergeAckDetail(outcome: CommandOutcome, additions: Map<String, String>): CommandOutcome {
        if (additions.isEmpty() || outcome !is CommandOutcome.Applied) return outcome
        return outcome.copy(detail = outcome.detail + additions)
    }
}
