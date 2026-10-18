package com.familyshield.agent.network.dto

/**
 * Body of `POST /v1/devices/:id/commands/:commandId/ack` (Phase 2b). [status] is `ok` or `failed`;
 * [detail] is stored as the row's `result` and read back by the parent's command history. Issue #132
 * sends `{"reason": "background_location_missing"}` for a refused `locate_now`.
 */
data class CommandAckDto(
    val status: String,
    val detail: Map<String, String>? = null,
)
