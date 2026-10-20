package com.familyshield.agent.security

/**
 * What [GuardianAdminReceiver.onDisabled] does once the OS reports the admin gone (issue #188).
 * Each value carries the effects the receiver must apply, so the decision is testable without
 * Android.
 */
enum class AdminDisabledOutcome(
    /** Write `admin_removed_by_parent`: the removal was the parent's own, not tamper. */
    val recordsParentRemoval: Boolean,
    /** Raise the durable pending flag so the next poll still alerts if the process dies first. */
    val marksAdminDisabledPending: Boolean,
    /** Enqueue the tamper alert now instead of waiting for the 60-s poll. */
    val enqueuesExpeditedAlert: Boolean,
) {
    /**
     * The parent verified the PIN inside the sanctioned window: record the deliberate removal and
     * leave the pending flag alone — it belongs to an out-of-band removal, not to this one.
     */
    SANCTIONED_PARENT_REMOVAL(
        recordsParentRemoval = true,
        marksAdminDisabledPending = false,
        enqueuesExpeditedAlert = false,
    ),

    /** No sanctioned window was open: this is an out-of-band removal and the parent is alerted. */
    TAMPER_ALERT(
        recordsParentRemoval = false,
        marksAdminDisabledPending = true,
        enqueuesExpeditedAlert = true,
    ),
}

/**
 * The pure decision behind [GuardianAdminReceiver.onDisabled] (issue #188). Device-admin removal is
 * asynchronous, so the caller cannot ask `isAdminActive()` afterwards to learn whether it happened;
 * the sanctioned window that [DeviceAdminManager.removeAdmin] opens is the only evidence that the
 * removal was the parent's. This policy turns that window into what the receiver must do, so the
 * boundary (`now == sanctionedUntilMs` is already outside) is decided and tested without Android.
 */
object AdminDisabledPolicy {
    fun classify(nowMs: Long, sanctionedUntilMs: Long): AdminDisabledOutcome =
        if (nowMs < sanctionedUntilMs) {
            AdminDisabledOutcome.SANCTIONED_PARENT_REMOVAL
        } else {
            AdminDisabledOutcome.TAMPER_ALERT
        }
}
