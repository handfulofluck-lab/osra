package com.familyshield.agent.ui.home

import com.familyshield.agent.network.dto.RuleSetDto
import java.time.DayOfWeek
import java.time.Duration
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Shared G5 time-left calculation for C-01 Child home (#1179). */
data class ChildTimeBudget(
    /** Effective limit for today (weekday/weekend base + local today bonus), or null if no daily limit is set. */
    val effectiveLimitMinutes: Int?,
    val usedMinutes: Int,
    /** Remaining minutes today (`>= 0`), or null when no daily limit is set. */
    val remainingMinutes: Int?,
    /** Fraction of daily budget remaining in `[0f, 1f]` for the C-01 ring. */
    val remainingFraction: Float,
)

/** Next upcoming routine today (or tomorrow if none left today). */
data class UpcomingRoutine(
    val name: String,
    val startHhMm: String,
    val startsInMinutes: Int,
)

/** Local record of a child's pending time/access request (G10). */
data class PendingChildRequest(
    val requestType: String, // "time" or "access"
    val minutes: Int?,
    val appLabel: String?,
    val sentAtMs: Long,
)

/** Lifecycle state of [PendingChildRequest] on C-01 (G10 age-out rule). */
enum class PendingRequestStatus {
    NONE,
    WAITING,
    NO_ANSWER_YET,
}

/** Send-button state for C-01 Requests tab (B2: never latch pending until POST succeeds). */
enum class TimeRequestSendState {
    IDLE,
    SENDING,
    FAILED,
}

/** Local record of a received parent decision for the C-01 Messages tab (G10). */
data class ChildDecisionRecord(
    val kind: String, // "bonus_time" | "rules_updated" | "pause_internet" | "resume_internet"
    val minutes: Int? = null,
    val byName: String? = null,
    val timestampMs: Long = 0L,
    val todayOnly: Boolean = false,
)

/**
 * Pure JVM policy for C-01 Child home + C-01-RTL (#1179):
 * - G5 shared ring formula: today's effective limit (weekend limit on Sat/Sun when > 0) + local today
 *   bonus minus today's minutes used.
 * - Upcoming routine discovery + bedtime display.
 * - G10 pending-request age-out (clears on incoming bonus/rule update, ages to "No answer yet" after 2 h).
 */
object ChildHomePolicy {

    /** G10: a pending request with no incoming grant/rule update ages out after 2 hours. */
    const val PENDING_AGE_OUT_MS: Long = 2L * 60L * 60L * 1000L

    /** U83 / Arabic Bureau 7207285631: hide the inside-ring unit caption above 1.3x text scale. */
    const val RING_CAPTION_MAX_FONT_SCALE: Float = 1.3f

    private val HH_MM: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

    /** Formats an integer with Western ASCII digits (`0-9`) regardless of the active device locale (#1191). */
    fun formatWesternInt(value: Int): String = String.format(Locale.US, "%d", value)

    /** True when the ring's unit caption fits inside the 96 dp ring without colliding with the number or stroke. */
    fun shouldShowRingCaption(fontScale: Float): Boolean = fontScale <= RING_CAPTION_MAX_FONT_SCALE

    fun timeBudget(
        ruleSet: RuleSetDto?,
        now: ZonedDateTime,
        minutesUsedToday: Map<String, Int>,
        localBonusMinutes: Int,
    ): ChildTimeBudget {
        val used = minutesUsedToday.values.sum().coerceAtLeast(0)
        val st = ruleSet?.screenTime
        if (st == null || st.dailyLimitMinutes <= 0) {
            return ChildTimeBudget(
                effectiveLimitMinutes = null,
                usedMinutes = used,
                remainingMinutes = null,
                remainingFraction = 1f,
            )
        }
        val local = now.toLocalDateTime()
        val isWeekend = local.dayOfWeek == DayOfWeek.SATURDAY || local.dayOfWeek == DayOfWeek.SUNDAY
        val base = if (isWeekend && st.weekendLimitMinutes > 0) st.weekendLimitMinutes else st.dailyLimitMinutes
        val effective = (base + localBonusMinutes.coerceAtLeast(0)).coerceAtLeast(1)
        val remaining = (effective - used).coerceAtLeast(0)
        val fraction = (remaining.toFloat() / effective.toFloat()).coerceIn(0f, 1f)
        return ChildTimeBudget(
            effectiveLimitMinutes = effective,
            usedMinutes = used,
            remainingMinutes = remaining,
            remainingFraction = fraction,
        )
    }

    /** Finds the soonest routine starting after [now] today (returns null if none configured). */
    fun nextRoutine(ruleSet: RuleSetDto?, now: ZonedDateTime): UpcomingRoutine? {
        val routines = ruleSet?.routines ?: return null
        val local = now.toLocalDateTime()
        val today = local.toLocalDate()
        val todayDow = local.dayOfWeek.value
        var best: Pair<LocalDateTime, String>? = null

        for (routine in routines) {
            val name = routine.name.trim()
            if (name.isEmpty()) continue
            val start = parseHhMm(routine.startTime) ?: continue
            if (todayDow in routine.days) {
                val candidate = today.atTime(start)
                if (candidate.isAfter(local)) {
                    if (best == null || candidate.isBefore(best.first)) {
                        best = candidate to name
                    }
                }
            }
        }
        val found = best ?: return null
        val mins = Duration.between(local, found.first).toMinutes().toInt().coerceAtLeast(1)
        return UpcomingRoutine(
            name = found.second,
            startHhMm = found.first.format(HH_MM),
            startsInMinutes = mins,
        )
    }

    /** Returns bedtime start `"HH:mm"` when bedtime is enabled (`start != end`), else null. */
    fun bedtimeStart(ruleSet: RuleSetDto?): String? {
        val st = ruleSet?.screenTime ?: return null
        val s = parseHhMm(st.bedtimeStart) ?: return null
        val e = parseHhMm(st.bedtimeEnd) ?: return null
        if (s == e) return null
        return s.format(HH_MM)
    }

    /** Classifies a local pending request under the G10 age-out rule. */
    fun pendingStatus(pending: PendingChildRequest?, nowMs: Long): PendingRequestStatus {
        if (pending == null) return PendingRequestStatus.NONE
        val elapsed = (nowMs - pending.sentAtMs).coerceAtLeast(0L)
        return if (elapsed >= PENDING_AGE_OUT_MS) {
            PendingRequestStatus.NO_ANSWER_YET
        } else {
            PendingRequestStatus.WAITING
        }
    }

    /**
     * G5 (#1179, B1): sum only today's accepted `bonus_time` decision records in `now.zone`.
     * Grants from earlier local days, non-bonus decisions, and any server `ruleSet.bonusMinutesToday`
     * aggregate are deliberately excluded.
     */
    fun bonusMinutesForToday(decisions: List<ChildDecisionRecord>, now: ZonedDateTime): Int {
        val today = now.toLocalDate()
        val zone = now.zone
        return decisions
            .asSequence()
            .filter { it.kind == "bonus_time" && (it.minutes ?: 0) > 0 && it.timestampMs > 0L }
            .filter { java.time.Instant.ofEpochMilli(it.timestampMs).atZone(zone).toLocalDate() == today }
            .sumOf { it.minutes ?: 0 }
    }

    /**
     * B2 (#1191): submits a C-01 time request and persists [PendingChildRequest] ONLY when
     * [postRequest] succeeds. A failed/offline POST returns `false` and leaves no false 2-hour
     * pending card behind.
     */
    suspend fun submitTimeRequest(
        minutes: Int,
        nowMs: Long,
        postRequest: suspend (Int) -> Result<Unit>,
        persistPending: (PendingChildRequest) -> Unit,
    ): Boolean {
        val allowed = if (minutes == 30) 30 else 15
        val result = postRequest(allowed)
        if (result.isSuccess) {
            persistPending(
                PendingChildRequest(
                    requestType = "time",
                    minutes = allowed,
                    appLabel = null,
                    sentAtMs = nowMs,
                ),
            )
            return true
        }
        return false
    }

    /** Formats epoch-ms in 24-hour Western digits `"HH:mm"` for "Sent to {adults} · 15:10". */
    fun formatClockHhMm(epochMs: Long, zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): String =
        java.time.Instant.ofEpochMilli(epochMs).atZone(zone).toLocalTime().format(HH_MM)

    private fun parseHhMm(value: String): LocalTime? =
        runCatching { LocalTime.parse(value.trim()) }.getOrNull()
}
