package com.familyshield.agent.security

/** What the app can say about a device-admin activation attempt (issue #186). */
enum class EnrolmentOutcome {
    /** The system sheet has not returned yet. */
    NOT_ATTEMPTED,

    /** Android reports an active admin (or a device owner): protection is on. */
    PROTECTED,

    /**
     * The sheet returned, Android reports no active admin, and this device has Knox. On Samsung the
     * usual cause is a stale Knox registry row that refuses the activation as "Admin is already added".
     */
    STALE_KNOX_ADMIN,

    /** The sheet returned without an admin and there is no Knox evidence to explain it. */
    NOT_GRANTED,
}

/**
 * Pure classifier behind the enrolment screen. It deliberately uses only what the app can observe
 * without reading Samsung's private registry: whether the sheet returned, what AOSP's
 * `DevicePolicyManager` reports, and whether a Knox admin API exists. A stale row is therefore
 * reported as a suspicion with a recovery route, never as a confirmed self-heal.
 */
object AdminEnrolmentPolicy {

    fun classify(
        sheetReturned: Boolean,
        isAdminActive: Boolean,
        isDeviceOwner: Boolean,
        knoxAvailable: Boolean,
    ): EnrolmentOutcome = when {
        !sheetReturned -> EnrolmentOutcome.NOT_ATTEMPTED
        isAdminActive || isDeviceOwner -> EnrolmentOutcome.PROTECTED
        knoxAvailable -> EnrolmentOutcome.STALE_KNOX_ADMIN
        else -> EnrolmentOutcome.NOT_GRANTED
    }
}

/** A user-facing explanation with the one action the app can offer. */
data class EnrolmentMessage(val title: String, val body: String, val recovery: String, val action: String)

/**
 * The wording for the stale-Knox dead end. It tells the parent what happened, names the Settings
 * route that goes through Knox, and is explicit that the app cannot clear the entry itself.
 */
object AdminEnrolmentMessages {

    fun forOutcome(outcome: EnrolmentOutcome): EnrolmentMessage? = when (outcome) {
        EnrolmentOutcome.STALE_KNOX_ADMIN -> EnrolmentMessage(
            title = "Protection could not be enabled",
            body = "Android reports no active OSRA device admin, but Samsung's Knox layer may still list " +
                "OSRA as an administrator. In that state the system sheet refuses Activate with " +
                "\"Admin is already added\" and closes without changing anything.",
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
