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
     * Issue #264 review (D2): may a future-dated row be imported, or does it predate the window?
     *
     * The read floor for SMS is a `DATE`, and a row dated ahead passes it whatever its age. Two paths then
     * imported text that belongs outside the window — a withdrawal round trip (the floor is the re-grant,
     * which is still on the forward clock) and a fresh install (a text received before OSRA existed, still
     * dated ahead). The `_ID` floor recorded when the read floor is set is what tells them apart: rows
     * above it did not exist when collection started.
     *
     * Only the **future** branch may consult this. `Telephony.Sms` has no AUTOINCREMENT, so deleting the
     * newest messages lets later ones reuse ids at or below the floor; gating normal rows on it would let a
     * child hide every later text by deleting their latest one.
     *
     * @param idFloor the newest SMS id at the moment collection was allowed, or a negative value when it
     *   could not be read then (the caller resolves it to the newest id it can see before the first use)
     */
    fun shouldImportFuture(rowId: Long, idFloor: Long): Boolean = idFloor < 0L || rowId > idFloor

    /** One row as the clock-back branch sees it: what an [entry] needs and nothing more. */
    data class ClockBackRow(val date: Long, val id: Long, val digest: String)

    /**
     * Issue #513: rows already read under the forward clock, remembered when the clock comes back.
     *
     * The hole: a text dated inside the skew is **not** future while the clock is ahead, so it takes the
     * normal path, is imported, and advances the watermark to its date. The clock then goes back; the
     * clock-back branch re-anchors the watermark to `now` and reads nothing. The harvest after that asks
     * for `DATE > now`, the same text is now future-dated, `tracked` is false because only future rows are
     * remembered — and it is imported a **second** time. Run 1 of T1 on the emulator did exactly that.
     *
     * So the clock-back branch remembers everything in `now < DATE <= stored` **without importing it**:
     * those rows were read once under the forward clock, and every one of them would otherwise look like a
     * brand-new future row. [prune] drops the entries once the real date passes them.
     *
     * The `<= stored` ceiling matters as much as the `> now` edge: a row dated beyond the old watermark was
     * never read, and remembering it would drop it for good — one duplicate traded for one lost message.
     *
     * @param stored the watermark that was in the future, i.e. the ceiling of what the forward clock read
     */
    fun seenOnClockBack(rows: List<ClockBackRow>, now: Long, stored: Long): Set<String> =
        rows.filter { it.date > now && it.date <= stored }
            .mapTo(LinkedHashSet()) { entry(it.date, it.id, it.digest) }

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
