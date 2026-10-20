package com.familyshield.agent.network.dto

/**
 * Body of `POST /v1/devices/:id/commands/:commandId/ack` (Phase 2b). [status] is `ok` or `failed`.
 *
 * Issue #231: `ok` means **the effect is observable to the parent**, not merely that the command
 * arrived or a handler was reached — the handler applied its synchronous effect; `locate_now` is
 * acked only once a fix exists; `wind_down` when the warning is posted and the timer armed (not
 * when the lock fires), and `rules_updated` when the refresh is accepted.
 *
 * [detail] is stored as the row's `result` and read back by the parent's command history: issue #132
 * sends `{"reason": "background_location_missing"}` for a refused `locate_now` (and
 * `{"reason": "command_failed"}` for a handler that threw), while a successful locate adds
 * `{"fix": "fresh" | "cached"}`.
 */
data class CommandAckDto(
    val status: String,
    val detail: Map<String, String>? = null,
)
