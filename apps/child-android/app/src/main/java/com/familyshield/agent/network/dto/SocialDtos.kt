package com.familyshield.agent.network.dto

/** Wire payloads for social scanning (Feature #2/#17), call/SMS activity (Feature #6) and live activity (Feature #29). */

/** Single redacted social/chat capture for POST /v1/social/scan. */
data class SocialScanDto(
    val childId: String,
    val deviceId: String,
    /** App key from MonitoredApps (whatsapp, discord, roblox, ...). */
    val app: String,
    /** Likely contact name/number, or null when the heuristic found none. */
    val contact: String? = null,
    /** Redacted message candidate (may be empty). */
    val text: String,
)

/** One activity event for POST /v1/devices/<id>/activity (Feature #6/#29, server ActivityEvent). */
data class ActivityEventDto(
    /** "call" | "sms" | "app_usage". */
    val type: String,
    /** Typed payload: CallActivityPayload, SmsActivityPayload or app_usage {app, minutes} values as a plain map. */
    val payload: Map<String, Any?>,
)

/** Batched activity upload for POST /v1/devices/<id>/activity. */
data class ActivityEventBatchDto(
    val events: List<ActivityEventDto>,
)

/** Payload of a call activity event. */
data class CallActivityPayload(
    val number: String,
    val durationSec: Int,
    /** incoming | outgoing | missed | other. */
    val direction: String,
)

/** Payload of an SMS activity event; [bodyPreview] is capped at 120 chars on the agent. */
data class SmsActivityPayload(
    val number: String,
    val bodyPreview: String,
)
