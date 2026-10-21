package com.familyshield.agent.comms

/**
 * Issue #229: when call/SMS collection starts.
 *
 * The watermark used to fall back to `0L` (`get(KEY_CALL_WATERMARK) ?: 0L`), so the first harvest
 * after the permission was granted queried `DATE > 0` and imported the phone's entire history — 1,986
 * calls back to 2026-01-23 in Claude's TR-24 run. Those calls predate both the parent's consent and
 * the grant.
 *
 * The rule is ADR-0008's: collection starts when it is allowed, never before. No watermark means
 * this is the first allowed harvest: store `now`, read nothing. The grant time is stored next to the
 * watermark (`comms_call_since` / `comms_sms_since`) and floors every later read, so even a stale
 * watermark cannot reach rows from before the current grant.
 *
 * Pure and Android-free so a JVM test can hold the rule; `CommsLogger` cannot run in this suite.
 */
object CommsWatermarkPolicy {

    /** The old `?: 0L`, a cleared key and a missing key all mean the same thing: no watermark. */
    fun normalize(stored: Long?): Long? = stored?.takeIf { it > 0L }

    /** The first harvest stores this value: the moment collection became allowed. */
    fun initialWatermark(existing: Long?, now: Long): Long = existing ?: now

    /** True when this harvest must store [initialWatermark] and read no rows. */
    fun isFirstHarvest(existing: Long?): Boolean = existing == null

    /**
     * The timestamp to query after, or **null** when there is nothing to read because collection has
     * not started yet. A configured grant time is a floor: rows before it are never read, even if a
     * watermark from an earlier grant survived a withdrawal the process did not observe.
     */
    fun startFrom(watermark: Long?, grantTime: Long?): Long? =
        watermark?.let { maxOf(it, grantTime?.takeIf { t -> t > 0L } ?: 0L) }
}
