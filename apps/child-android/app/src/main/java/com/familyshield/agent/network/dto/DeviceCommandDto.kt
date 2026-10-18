package com.familyshield.agent.network.dto

/** Pending parent command drained from GET /v1/devices/<id>/commands (§14.2 FCM-free polling). */
data class DeviceCommandDto(
    /** Durable queue row id (Phase 2b); `locate_now` reports a refusal back against it. */
    val id: String = "",
    val type: String = "",
    val payload: Map<String, Any>? = null,
)
