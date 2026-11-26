package com.familyshield.agent.setup

import android.content.Context

/** Unpaired first-run onboarding stage for C-05 + #1174 (permissions before pairing). */
enum class PrePairStage {
    WELCOME,
    PRE_PAIR_PERMISSIONS,
    PRE_PAIR_CHECKLIST,
    PAIRING_FORM,
}

/** One-time upgrade migration decision for pre-existing paired phones (osra-security#80). */
data class UpgradeSeedDecision(
    val seedLatch: Boolean,
    val markMigrated: Boolean,
)

/**
 * Issue #1174, C-05 First run (#1179), and osra-security#80:
 * 1. Required permissions (`OnboardingPolicy.canComplete(rows)`) run **before** the pairing code
 *    step so rules cannot start blocking setup screens mid-onboarding (e.g. Redmi Xiaomi Security).
 * 2. On a fresh paired phone whose initial required-grants setup has **never** completed yet, ALL
 *    three enforcement paths (settings guard / PIN gate, filter-lost screen, app-block / routine
 *    blocks) are suppressed until all required grants finish for the first time, while one
 *    deduplicated parent alert (`setup_incomplete:<deviceId>`) lists the missing permissions.
 * 3. Once required grants have completed once — OR when an already-paired device upgrades from an
 *    earlier build (`upgradeSeedDecision`) — enforcement is **never** suppressed again. Newly
 *    required grants missing on an upgraded phone are reported via one missing-permissions alert
 *    while keeping protection active.
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
     * osra-security#80 upgrade path: on first run of this build (`!upgradeMigrated`), any device
     * that was already paired before the update (`hasExistingPairedDeviceId && !alreadyLatched`)
     * seeds the completion latch immediately without requiring the live grant set so existing
     * protected phones never lose blocking after updating.
     */
    fun upgradeSeedDecision(
        upgradeMigrated: Boolean,
        hasExistingPairedDeviceId: Boolean,
        alreadyLatched: Boolean,
    ): UpgradeSeedDecision {
        if (upgradeMigrated) return UpgradeSeedDecision(seedLatch = false, markMigrated = false)
        return UpgradeSeedDecision(
            seedLatch = hasExistingPairedDeviceId && !alreadyLatched,
            markMigrated = true,
        )
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
     * True only when the missing-permissions parent alert should be enqueued/updated:
     * - paired and at least one required grant is missing;
     * - either initial setup has not completed once yet (`!setupCompletedOnce`) OR the device was
     *   upgrade-seeded from an earlier build and has newly required grants missing (`upgradeSeeded`);
     * - the missing set changed since the last alert (no repeats).
     */
    fun shouldEnqueueMissingAlert(
        paired: Boolean,
        setupCompletedOnce: Boolean,
        currentFingerprint: String,
        lastNotifiedFingerprint: String?,
        upgradeSeeded: Boolean = false,
    ): Boolean {
        if (!paired || currentFingerprint.isBlank()) return false
        if (setupCompletedOnce && !upgradeSeeded) return false
        return currentFingerprint != lastNotifiedFingerprint
    }

    /**
     * Claude (#1208, 7202013057): drop any queued `setup_incomplete:<deviceId>` alert at send time
     * once setup has completed (unless still reporting newly required grants on an upgrade-seeded
     * pairing).
     */
    fun shouldDropSetupIncompleteAtSendTime(
        setupCompletedOnce: Boolean,
        upgradeSeededWithMissingGrants: Boolean = false,
    ): Boolean = setupCompletedOnce && !upgradeSeededWithMissingGrants

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
 *
 * Also tracks a one-time `upgrade_latch_seeded_v1` migration flag so already-paired devices
 * updating from an earlier build are seeded without losing protection; [clear] deliberately
 * preserves that migration flag so a later fresh re-pair is never mistaken for an upgrade.
 */
object SetupCompletionStore {
    private const val PREFS = "osra_setup_completion_v1"
    private const val KEY_COMPLETED_DEVICE_ID = "completed_device_id"
    private const val KEY_UPGRADE_MIGRATED = "upgrade_latch_seeded_v1"
    private const val KEY_UPGRADE_SEEDED_DEVICE_ID = "upgrade_seeded_device_id"
    private const val KEY_ALERTED_DEVICE_ID = "alerted_device_id"
    private const val KEY_ALERTED_MISSING_FP = "alerted_missing_fp"

    fun isCompletedForDevice(context: Context, deviceId: String?): Boolean {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val stored = prefs(context).getString(KEY_COMPLETED_DEVICE_ID, null)?.trim()
        return stored == current
    }

    fun isUpgradeSeededForDevice(context: Context, deviceId: String?): Boolean {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val stored = prefs(context).getString(KEY_UPGRADE_SEEDED_DEVICE_ID, null)?.trim()
        return stored == current
    }

    /**
     * Runs once on the first execution of this build: if a paired `deviceId` already existed before
     * the upgrade, seeds the completion latch immediately so protection stays on. Returns true if
     * the latch is now seeded for an upgraded device.
     */
    fun seedUpgradeLatchIfNeeded(context: Context, existingPairedDeviceId: String?): Boolean {
        val p = prefs(context)
        val migrated = p.getBoolean(KEY_UPGRADE_MIGRATED, false)
        val trimmedId = existingPairedDeviceId?.trim()?.takeIf { it.isNotEmpty() }
        val alreadyLatched = isCompletedForDevice(context, trimmedId)
        val decision = FirstRunOrderPolicy.upgradeSeedDecision(
            upgradeMigrated = migrated,
            hasExistingPairedDeviceId = trimmedId != null,
            alreadyLatched = alreadyLatched,
        )
        if (!decision.markMigrated) return isUpgradeSeededForDevice(context, trimmedId)
        val editor = p.edit().putBoolean(KEY_UPGRADE_MIGRATED, true)
        if (decision.seedLatch && trimmedId != null) {
            editor.putString(KEY_COMPLETED_DEVICE_ID, trimmedId)
            editor.putString(KEY_UPGRADE_SEEDED_DEVICE_ID, trimmedId)
        }
        editor.apply()
        return decision.seedLatch
    }

    /** Marks the one-time upgrade check done before saving a fresh pairing on this build. */
    fun markUpgradeMigrated(context: Context) {
        prefs(context).edit().putBoolean(KEY_UPGRADE_MIGRATED, true).apply()
    }

    fun markCompleted(context: Context, deviceId: String?) {
        val current = deviceId?.trim()?.takeIf { it.isNotEmpty() } ?: return
        prefs(context).edit()
            .putBoolean(KEY_UPGRADE_MIGRATED, true)
            .putString(KEY_COMPLETED_DEVICE_ID, current)
            .remove(KEY_UPGRADE_SEEDED_DEVICE_ID)
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

    /** Clears per-pairing state on unpair/re-pair while keeping the one-time upgrade migration flag. */
    fun clear(context: Context) {
        prefs(context).edit()
            .remove(KEY_COMPLETED_DEVICE_ID)
            .remove(KEY_UPGRADE_SEEDED_DEVICE_ID)
            .remove(KEY_ALERTED_DEVICE_ID)
            .remove(KEY_ALERTED_MISSING_FP)
            .putBoolean(KEY_UPGRADE_MIGRATED, true)
            .apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
