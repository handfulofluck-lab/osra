package com.familyshield.agent.comms

import java.security.MessageDigest

/**
 * Issue #264 (F1): a text received while the clock is set forward is imported **once**, not a year late.
 *
 * `harvestSms` skips a row dated beyond the skew so a bad date cannot drag the watermark into the future.
 * The cost was that the row was re-selected and skipped on every harvest until the real date caught up —
 * up to a year — instead of reaching the parent at the next flush. Importing it without moving the
 * watermark is not enough on its own, because then it is imported every five minutes.
 *
 * So the identity of each already-imported future row is kept: `date|id|addressDigest`. The id alone is
 * not enough (`Telephony.Sms._id` can be reused; the table has no AUTOINCREMENT), and the address is
 * digested rather than stored because a parent's preference file should not hold a contact's number.
 *
 * Pure and Android-free so the window rule is a JVM test; `CommsLogger` cannot run in this suite.
 */
object CommsFutureSmsPolicy {

    /**
     * How many identities are remembered.
     *
     * A child would have to receive this many messages while the clock is ahead, with no successful
     * harvest in between, for an entry to be dropped — and a dropped entry costs one duplicate upload,
     * not a lost message.
     */
    const val MAX_TRACKED = 200

    /** The identity of one future-dated row. `date` first so [prune] can read it back without parsing. */
    fun entry(rowDate: Long, rowId: Long, addressDigest: String): String =
        "$rowDate|$rowId|$addressDigest"

    /** True when this row has already been imported while it was future-dated. */
    fun isTracked(seen: Set<String>, entry: String): Boolean = entry in seen

    /**
     * Drops entries the watermark has passed: once `comms_sms_watermark` reaches a row's date, normal
     * collection covers it and the identity has no further use.
     */
    fun prune(seen: Set<String>, watermark: Long): Set<String> =
        seen.filterTo(LinkedHashSet()) { entry ->
            val date = entry.substringBefore('|').toLongOrNull() ?: 0L
            date > watermark
        }

    /** Adds one entry, keeping the newest [MAX_TRACKED] by row date when the set is full. */
    fun remember(seen: Set<String>, entry: String): Set<String> {
        val next = LinkedHashSet(seen)
        next.add(entry)
        if (next.size <= MAX_TRACKED) return next
        return next
            .sortedByDescending { it.substringBefore('|').toLongOrNull() ?: 0L }
            .take(MAX_TRACKED)
            .toCollection(LinkedHashSet())
    }

    /**
     * A short, stable digest of a phone number, so the persisted set cannot be read as a contact list.
     *
     * Not a secret and not meant to resist a determined reader of the preference file — it removes the
     * plain number from storage, which is the property that matters for a child's phone.
     */
    fun digest(address: String): String {
        if (address.isEmpty()) return ""
        val bytes = MessageDigest.getInstance("SHA-256").digest(address.toByteArray(Charsets.UTF_8))
        return bytes.take(6).joinToString("") { "%02x".format(it) }
    }
}
