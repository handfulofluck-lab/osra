package com.familyshield.agent.ui.home

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * G10 (#1179): lightweight local persistence for C-01 Child home:
 * - active pending child request (prevents duplicate sends, clears on incoming bonus/rules update,
 *   ages out to "No answer yet" after [ChildHomePolicy.PENDING_AGE_OUT_MS]),
 * - bounded local log of parent decisions received via [com.familyshield.agent.commands.CommandDispatcher]
 *   (bonus time with optional `byName`, rules updated, pause/resume internet),
 * - active wind-down deadline for the C-01 wind-down banner.
 */
object ChildHomeStore {

    private const val PREFS_NAME = "osra_child_home_v1"
    private const val KEY_PENDING = "pending_request"
    private const val KEY_DECISIONS = "decisions"
    private const val KEY_WIND_DOWN_UNTIL = "wind_down_until_ms"
    private const val MAX_DECISIONS = 20

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun savePendingRequest(context: Context, request: PendingChildRequest) {
        val obj = JSONObject().apply {
            put("requestType", request.requestType)
            if (request.minutes != null) put("minutes", request.minutes)
            if (!request.appLabel.isNullOrBlank()) put("appLabel", request.appLabel)
            put("sentAtMs", request.sentAtMs)
        }
        prefs(context).edit().putString(KEY_PENDING, obj.toString()).apply()
    }

    fun pendingRequest(context: Context): PendingChildRequest? {
        val raw = prefs(context).getString(KEY_PENDING, null) ?: return null
        return runCatching {
            val obj = JSONObject(raw)
            PendingChildRequest(
                requestType = obj.optString("requestType", "time"),
                minutes = if (obj.has("minutes")) obj.optInt("minutes") else null,
                appLabel = obj.optString("appLabel", "").takeIf { it.isNotBlank() },
                sentAtMs = obj.optLong("sentAtMs", 0L),
            )
        }.getOrNull()
    }

    fun clearPendingRequest(context: Context) {
        prefs(context).edit().remove(KEY_PENDING).apply()
    }

    fun recordDecision(context: Context, decision: ChildDecisionRecord) {
        val current = decisions(context).toMutableList()
        current.add(0, decision)
        val trimmed = current.take(MAX_DECISIONS)
        val array = JSONArray()
        for (item in trimmed) {
            array.put(
                JSONObject().apply {
                    put("kind", item.kind)
                    if (item.minutes != null) put("minutes", item.minutes)
                    if (!item.byName.isNullOrBlank()) put("byName", item.byName)
                    put("timestampMs", item.timestampMs)
                    put("todayOnly", item.todayOnly)
                },
            )
        }
        prefs(context).edit().putString(KEY_DECISIONS, array.toString()).apply()
    }

    fun decisions(context: Context): List<ChildDecisionRecord> {
        val raw = prefs(context).getString(KEY_DECISIONS, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (i in 0 until array.length()) {
                    val obj = array.optJSONObject(i) ?: continue
                    add(
                        ChildDecisionRecord(
                            kind = obj.optString("kind", ""),
                            minutes = if (obj.has("minutes")) obj.optInt("minutes") else null,
                            byName = obj.optString("byName", "").takeIf { it.isNotBlank() },
                            timestampMs = obj.optLong("timestampMs", 0L),
                            todayOnly = obj.optBoolean("todayOnly", false),
                        ),
                    )
                }
            }
        }.getOrDefault(emptyList())
    }

    fun setWindDownUntil(context: Context, endsAtMs: Long) {
        prefs(context).edit().putLong(KEY_WIND_DOWN_UNTIL, endsAtMs).apply()
    }

    fun clearWindDown(context: Context) {
        prefs(context).edit().remove(KEY_WIND_DOWN_UNTIL).apply()
    }

    /** Remaining whole minutes in an active wind-down, or null if none is active. */
    fun windDownMinutesLeft(context: Context, nowMs: Long = System.currentTimeMillis()): Int? {
        val until = prefs(context).getLong(KEY_WIND_DOWN_UNTIL, 0L)
        if (until <= nowMs) return null
        val diffMs = until - nowMs
        return ((diffMs + 59_999L) / 60_000L).toInt().coerceAtLeast(1)
    }

    fun clearAll(context: Context) {
        prefs(context).edit().clear().apply()
    }
}
