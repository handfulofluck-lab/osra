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

    /**
     * Issue #260: five minutes is the most a phone clock may legitimately be ahead of the server.
     *
     * A child can set the clock forward once, make one call dated a year ahead, and every later call
     * then has a `DATE` below the watermark — call logging stops silently until that date arrives. The
     * same skew is clamped on the server for the timestamp itself (`devices.ts`, `activityEventTs`).
     */
    const val CLOCK_SKEW_MS = 5 * 60_000L

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

    /**
     * Issue #260: a stored watermark or grant time further ahead than the skew means the clock moved back.
     *
     * The SMS stream keeps a `DATE` watermark, so a phone that was set a year forward leaves one year in
     * the future and drops every real message afterwards. The same applies to the stored *grant* time
     * (`comms_call_since` / `comms_sms_since`): it is the read floor, and clamping it at read time does
     * not help, because `now` moves each harvest and the floor stays ahead of it — so the caller
     * re-anchors the stored value to `now` once. The rows dated during the excursion cannot be placed
     * honestly by any watermark, and one lost window is better than collecting nothing until the bad
     * date arrives.
     */
    fun isClockBack(stored: Long?, now: Long): Boolean =
        stored != null && stored > now + CLOCK_SKEW_MS

    /** True when a row is dated more than the skew ahead of now, so it cannot advance the watermark. */
    fun isFutureRow(rowTime: Long, now: Long): Boolean = rowTime > now + CLOCK_SKEW_MS

    /** What to store as a `DATE` watermark: the newest row read, never a time in the future. */
    fun nextWatermark(newest: Long, now: Long): Long = minOf(newest, now)

    /**
     * Issue #264 (F2): does a call row belong in the collection window?
     *
     * The `DATE` floor alone was wrong in one direction: a call made with the clock set *back* to before
     * the grant has a higher `_ID` (it is a new row) and an older `DATE`, so `DATE >= floor` excluded it
     * forever while the id watermark walked past it. Rows are written when a call **ends**, so with the
     * anchor at "the newest id that ended by the floor", a higher id whose whole span is before the floor
     * can only come from a clock set back — and it is read; the server bounds its time (#263).
     *
     * The other direction is ADR-0008's: a call that started before the floor and ended after it happened
     * *through* the pause, so it stays out. That is the straddle, and the skew is the tolerance around the
     * floor rather than a second window.
     */
    fun shouldReadCall(rowDate: Long, durationSec: Long, floor: Long): Boolean {
        if (floor <= 0L) return true
        if (rowDate >= floor) return true
        val end = rowDate + durationSec * 1000L
        if (end + CLOCK_SKEW_MS >= floor) return false
        return true
    }

    /**
     * Issue #260: calls are watermarked by `CallLog._ID`, not `DATE`.
     *
     * `DATE` is when a call *started* but the row is written when it *ends*, so a 290-second call with a
     * short call answered during it ends last and carries the older `DATE`: the short call raised the
     * watermark past it and the long call was never read. `_ID` is monotonic and never reused, so the
     * long call is simply the next id. `null` means nothing has been read yet.
     */
    fun shouldReadById(rowId: Long, watermarkId: Long?): Boolean =
        watermarkId == null || rowId > watermarkId
}
