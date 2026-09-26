package com.familyshield.agent.telemetry

import com.familyshield.agent.network.dto.ActivityEventDto

/**
 * Pure builder for the Feature #29 live-activity event posted to POST /v1/devices/<id>/activity.
 * [snapshot] is today's per-app minutes; the payload carries the running total across apps and the
 * foreground package, or "idle" when no foreground transition has been recorded yet.
 */
fun liveActivityPayload(snapshot: Map<String, Int>, foreground: String?): ActivityEventDto {
    val app = foreground ?: "idle"
    val minutes = snapshot.values.sum()
    return ActivityEventDto(type = "app_usage", payload = mapOf("app" to app, "minutes" to minutes))
}
