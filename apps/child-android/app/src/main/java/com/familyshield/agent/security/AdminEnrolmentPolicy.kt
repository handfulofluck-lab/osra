package com.familyshield.agent.security

/** What the app can say about a device-admin activation attempt (issue #186). */
enum class EnrolmentOutcome {
    /** The system sheet has not returned yet. */
    NOT_ATTEMPTED,

    /** Android reports an active admin (or a device owner): protection is on. */
    PROTECTED,

    /**
     * The sheet returned, Android reports no active admin, and the sheet itself refused as "Admin is
     * already added" — the shape a stale Knox registry row takes. Knox merely existing is not this.
     */
    STALE_KNOX_ADMIN,

    /** The sheet returned without an admin and without an already-added refusal. */
    NOT_GRANTED,
}

/** What the status screen may add below an "alert-only" tier (issue #188). */
enum class ProtectionStatusNote {
    /** Nothing beyond the tier line. */
    NONE,

    /** This app removed its own admin through the parent PIN: say so, without blaming Knox. */
    REMOVED_BY_PARENT,
}

/**
 * Pure classifier behind the enrolment screen. It deliberately uses only what the app can observe
 * without reading Samsung's private registry: whether the sheet returned, what AOSP's
 * `DevicePolicyManager` reports, and whether the sheet closed itself with the already-added refusal.
 * Knox merely existing on the device says nothing about a stale row (#188): a parent who backs out of
 * the sheet is an ordinary [EnrolmentOutcome.NOT_GRANTED], not an alarm about a factory reset.
 */
object AdminEnrolmentPolicy {

    /**
     * How long after launch a cancelled sheet is read as Samsung's "Admin is already added" refusal.
     * A parent tapping Cancel or Back has to read the screen first; the refusal closes it by itself.
     */
    const val ALREADY_ADDED_REFUSAL_MAX_MS = 1_000L

    fun classify(
        sheetReturned: Boolean,
        isAdminActive: Boolean,
        isDeviceOwner: Boolean,
        knoxAvailable: Boolean,
        alreadyAddedRefusal: Boolean = false,
    ): EnrolmentOutcome = when {
        !sheetReturned -> EnrolmentOutcome.NOT_ATTEMPTED
        isAdminActive || isDeviceOwner -> EnrolmentOutcome.PROTECTED
        alreadyAddedRefusal && knoxAvailable -> EnrolmentOutcome.STALE_KNOX_ADMIN
        else -> EnrolmentOutcome.NOT_GRANTED
    }

    /**
     * The observed shape of the "Admin is already added" refusal (issue #188): the system sheet
     * closes itself with `RESULT_CANCELED` almost immediately, without waiting for a user decision.
     * On a non-Samsung device there is no Knox row to be stale, so [classify] still says not granted.
     */
    fun isAlreadyAddedRefusal(resultOk: Boolean, elapsedSinceLaunchMs: Long): Boolean =
        !resultOk && elapsedSinceLaunchMs in 0..ALREADY_ADDED_REFUSAL_MAX_MS

    /** A successful activation proves there is no stuck record left, so the memory is dropped. */
    fun clearsParentRemoval(outcome: EnrolmentOutcome): Boolean =
        outcome == EnrolmentOutcome.PROTECTED

    /**
     * The status screen's note under the tier line. It never infers a stale Knox row from the
     * presence of a Knox API (#188) — that text belongs to [EnrolmentOutcome.STALE_KNOX_ADMIN]
     * only, which requires an observed refusal.
     */
    fun statusNote(tier: ProtectionTier, adminRemovedByParent: Boolean): ProtectionStatusNote = when {
        tier != ProtectionTier.NONE -> ProtectionStatusNote.NONE
        adminRemovedByParent -> ProtectionStatusNote.REMOVED_BY_PARENT
        else -> ProtectionStatusNote.NONE
    }
}

/** A user-facing explanation with the one action the app can offer. */
data class EnrolmentMessage(val title: String, val body: String, val recovery: String, val action: String)

/**
 * The wording for the stale-Knox dead end. It tells the parent what happened, names the Settings
 * route that goes through Knox, and is explicit that the app cannot clear the entry itself.
 */
object AdminEnrolmentMessages {

    /** Shown under an alert-only tier after the parent removed protection deliberately (#188). */
    const val PARENT_REMOVAL_NOTE =
        "Protection was removed with the parent PIN. Tap Activate device admin to turn it back on."

    fun forOutcome(outcome: EnrolmentOutcome): EnrolmentMessage? = when (outcome) {
        EnrolmentOutcome.STALE_KNOX_ADMIN -> EnrolmentMessage(
            title = "Protection could not be enabled",
            body = "The system sheet closed without activating anything. Samsung's Knox layer still " +
                "lists OSRA as an administrator, so the system refuses Activate with " +
                "\"Admin is already added\".",
            recovery = "Open Settings → Security and privacy → Device admin apps, deactivate OSRA if it " +
                "is listed, then return here and tap Activate device admin. If OSRA is not listed there, " +
                "only a factory reset or system-level access can clear the stale entry.",
            action = "Open device admin settings",
        )
        EnrolmentOutcome.NOT_ATTEMPTED,
        EnrolmentOutcome.PROTECTED,
        EnrolmentOutcome.NOT_GRANTED,
        -> null
    }
}
