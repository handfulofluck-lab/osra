package com.familyshield.agent.comms

/**
 * Issue #229: which `CallLog` rows become `comms_events`.
 *
 * Google Meet writes an answered call into the system call log with **no number** and a non-empty
 * `subscription_component_name` (the VoIP app), and Claude's TR-24 run found one call written twice
 * with the same timestamp. Both copies were imported.
 *
 * A numberless app row carries nothing the parent screen can act on: the timeline shows a number and
 * has no app column, and the unknown-contact alert (#27) needs digits. Such a row is therefore
 * **skipped**, not stored as an app-only event — recording `app=<package>` would need a new field in
 * the Room entity, the upload payload and the parent timeline for a call the parent cannot identify.
 * Meet calls that were never answered never reached the call log at all, so they are not visible here
 * either; the parent-facing copy now says "phone calls" for exactly that reason.
 *
 * The duplicate rule is per harvest: the identity the provider repeats is
 * `(date, type, duration, component)`. A later harvest may legitimately see the same identity again
 * (it is queried above the watermark, so normally it will not), and the watermark is the durable
 * guard against re-importing across harvests.
 *
 * Pure and Android-free; `CommsLogger` supplies the cursor values.
 */
object CommsRowPolicy {

    /** The fields one call row is deduplicated on inside a single harvest. */
    data class Identity(
        val dateMs: Long,
        val type: Int,
        val durationSec: Long,
        val component: String?,
    )

    /** A row with no number and a VoIP account component: an app call, not a phone call. */
    fun isNumberlessAppCall(number: String?, component: String?): Boolean =
        number.isNullOrBlank() && !component.isNullOrBlank()

    /** Import only a numbered row that this harvest has not already seen. */
    fun shouldImport(
        number: String?,
        component: String?,
        identity: Identity,
        seenInThisHarvest: Set<Identity>,
    ): Boolean = !isNumberlessAppCall(number, component) && identity !in seenInThisHarvest
}
