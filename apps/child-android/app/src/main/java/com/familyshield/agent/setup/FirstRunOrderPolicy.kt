package com.familyshield.agent.setup

import android.content.Context

/** Unpaired first-run onboarding stage for C-05 + #1174 (permissions before pairing). */
enum class PrePairStage {
    WELCOME,
    PRE_PAIR_PERMISSIONS,
    PRE_PAIR_CHECKLIST,
    PAIRING_FORM,
}

/**
 * Issue #1174, C-05 First run (#1179), and osra-security#80:
 * 1. Required permissions (`OnboardingPolicy.canComplete(rows)`) run **before** the pairing code
 *    step so rules cannot start blocking setup screens mid-onboarding (e.g. Redmi Xiaomi Security).
 * 2. On a paired phone whose initial required-grants setup has **never** completed yet, ALL three
 *    enforcement paths (settings guard / PIN gate, filter-lost screen, app-block / routine blocks)
 *    are suppressed until all required grants finish for the first time, while one deduplicated
 *    parent alert lists the missing permissions.
 * 3. Once required grants have completed once for the current pairing (`setupCompletedOnce == true`),
 *    enforcement is **never** suppressed again — losing a grant later (Private DNS, VPN, Location,
 *    Overlay, Usage) keeps enforcing everything that still works and relies on existing tamper alerts.
 */
object FirstRunOrderPolicy {

    /** Minimum interval between live GrantChecks reads while initial setup is still incomplete. */
    const val INCOMPLETE_RECHECK_INTERVAL_MS: Long = 1_000L

    fun resolveUnpairedStage(
        welcomeCompleted: Boolean,
        requiredGrantsReady: Boolean,
        forceChecklist: Boolean,
        hasTypedOrScannedPairing: Boolean,
        c05Enabled: Boolean = true,
    ): PrePairStage {
        if (hasTypedOrScannedPairing) return PrePairStage.PAIRING_FORM
        if (!welcomeCompleted) return PrePairStage.WELCOME
        if (!c05Enabled || requiredGrantsReady) return PrePairStage.PAIRING_FORM
        return if (forceChecklist) PrePairStage.PRE_PAIR_CHECKLIST else PrePairStage.PRE_PAIR_PERMISSIONS
    }

    /**
     * Suppresses protection paths (settings guard, filter-lost recovery, app/routine blocks)
     * **only** while paired AND initial setup has never completed once for this pairing
     * (`!setupCompletedOnce`) AND required grants are not yet ready.
     */
    fun shouldSuppressEnforcement(
        paired: Boolean,
        requiredGrantsReady: Boolean,
        setupCompletedOnce: Boolean,
    ): Boolean {
        if (!paired) return false
        if (setupCompletedOnce) return false
        return !requiredGrantsReady
    }

    /** Stable sorted fingerprint for a non-empty list of missing required grants, or empty when complete. */
    fun missingGrantsFingerprint(missing: List<OnboardingPolicy.Grant>): String =
        missing.map { it.name }.distinct().sorted().joinToString(",")

    /**
     * True only when the missing-permissions parent alert should be enqueued/updated: paired,
     * initial setup has never completed once, at least one required grant is missing, and the
     * missing set changed since the last alert (no repeats).
     */
    fun shouldEnqueueMissingAlert(
        paired: Boolean,
        setupCompletedOnce: Boolean,
        currentFingerprint: String,
        lastNotifiedFingerprint: String?,
    ): Boolean {
        if (!paired || setupCompletedOnce || currentFingerprint.isBlank()) return false
        return currentFingerprint != lastNotifiedFingerprint
    }

    /** Human-readable alert body listing the missing required permissions for the parent. */
    fun missingPermissionsAlertBody(missingLabels: List<String>): String {
        val clean = missingLabels.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        return if (clean.isEmpty()) {
            "Some required permissions are still missing on this device. Protection will start once setup finishes."
        } else {
            "Setup is not finished yet. Missing required permissions: ${clean.joinToString(", ")}. Protection will start once all required permissions are granted."
        }
    }
}

/**
 * Persisted one-way latch recording that required onboarding grants completed at least once for
 * the current paired device id. Keyed to `deviceId` so re-pairing under a new device id starts
 * clean, while revoking any grant after first completion never clears the latch (osra-security#80).
 */
object SetupCompletionStore {
    private const val PREFS = "osra_setup_completion_v1"
    private const val KEY_COMPLETED_DEVICE_ID = "completed_device_id"
    private const val KEY_ALERTED_DEVICE_ID = "alerted_device_id"
    private const val KEY_ALERTED_MISSING_FP = "alerted_missing_fp"

    fun isCompletedForDevice(context: Context, deviceId: String?): Boolean {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val stored = prefs(context).getString(KEY_COMPLETED_DEVICE_ID, null)?.trim()
        return stored == current
    }

    fun markCompleted(context: Context, deviceId: String?) {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return
        prefs(context).edit()
            .putString(KEY_COMPLETED_DEVICE_ID, current)
            .remove(KEY_ALERTED_DEVICE_ID)
            .remove(KEY_ALERTED_MISSING_FP)
            .apply()
    }

    fun lastNotifiedMissingFingerprint(context: Context, deviceId: String?): String? {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val p = prefs(context)
        if (p.getString(KEY_ALERTED_DEVICE_ID, null)?.trim() != current) return null
        return p.getString(KEY_ALERTED_MISSING_FP, null)?.takeIf { it.isNotBlank() }
    }

    fun recordNotifiedMissingFingerprint(context: Context, deviceId: String?, fingerprint: String) {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return
        prefs(context).edit()
            .putString(KEY_ALERTED_DEVICE_ID, current)
            .putString(KEY_ALERTED_MISSING_FP, fingerprint)
            .apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
