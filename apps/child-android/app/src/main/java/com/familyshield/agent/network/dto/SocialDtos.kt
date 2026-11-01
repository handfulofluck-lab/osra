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
    /** screen | notification (plan 2.6). */
    val source: String = "screen",
)

/** #490: one flush as one request — at most `ScanQueuePolicy.ITEMS_PER_REQUEST` captures. */
data class SocialScanBatchDto(val items: List<SocialScanDto>)

/** #490: the server answers each item of a batch on its own, in the order sent. */
data class SocialScanBatchResultDto(val results: List<SocialScanItemResultDto> = emptyList())

/** `ok` false carries the server's reason (`child_not_found`, `invalid_item`, …); the row is counted down. */
data class SocialScanItemResultDto(val ok: Boolean, val reason: String? = null)

/** One activity event for POST /v1/devices/<id>/activity (Feature #6/#29, server ActivityEvent). */
data class ActivityEventDto(
    /** "call" | "sms" | "app_usage". */
    val type: String,
    /** Typed payload: CallActivityPayload, SmsActivityPayload or app_usage {app, minutes} values as a plain map. */
    val payload: Map<String, Any?>,
    /**
     * When the event happened, ISO-8601 UTC, or null for "now".
     *
     * Issue #260: the server stamps `new Date()` when this is absent, so every row in a batch was dated
     * to the moment of the 5-minute flush -- two calls eight seconds apart arrived with the same
     * timestamp, and a phone offline for hours dated all its calls to the reconnect. The comms queue
     * already carries the event time (`CommsEventEntity.timestamp`); this is the field that sends it.
     */
    val ts: String? = null,
)

/** Batched activity upload for POST /v1/devices/<id>/activity. */
data class ActivityEventBatchDto(
    val events: List<ActivityEventDto>,
)

/** Payload of a call activity event. */
data class CallActivityPayload(
    /**
     * The call log's number, or — for a WhatsApp call (roadmap 4.5) — the contact name WhatsApp gave us. It is
     * the row's label on the parent screen, and WhatsApp never shows a number.
     */
    val number: String,
    /**
     * Seconds, or **absent** when the length was not measured. Never `0` for "unknown": the parent app reads a
     * present 0 as a call that connected and ended instantly (roadmap 4.5, #526).
     */
    val durationSec: Int? = null,
    /** incoming | outgoing | missed | unknown | other. */
    val direction: String,
    /** `whatsapp` when the call was read from WhatsApp's notifications; absent for a carrier call. */
    val source: String? = null,
    /** True when [durationSec] was measured from notifications rather than timed, so the screen says "about". */
    val durationApprox: Boolean = false,
)

/** Payload of an SMS activity event; [bodyPreview] is capped at 120 chars on the agent. */
data class SmsActivityPayload(
    val number: String,
    val bodyPreview: String,
)
