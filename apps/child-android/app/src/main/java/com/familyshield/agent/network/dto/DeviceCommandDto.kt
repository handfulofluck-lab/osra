package com.familyshield.agent.network.dto

/** Pending parent command drained from GET /v1/devices/<id>/commands (§14.2 FCM-free polling). */
data class DeviceCommandDto(
    val type: String = "",
    val payload: Map<String, Any>? = null,
)
