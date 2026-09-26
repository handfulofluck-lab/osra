package com.familyshield.agent.network.dto

/** Wire payloads for the OSRA backend (pure Kotlin / Moshi models). */

/** A single location sample; [timestamp] is an ISO-8601 instant. */
data class LocationPingDto(
    val lat: Double,
    val lng: Double,
    val accuracyM: Float,
    val timestamp: String,
)

/** Batched location upload for POST /v1/location/ping. */
data class LocationPingBatchDto(
    val pings: List<LocationPingDto>,
)

/** Aggregated usage delta for POST /v1/devices/<id>/telemetry. */
data class TelemetryDto(
    val perAppMinutes: Map<String, Int>,
    val totalMinutes: Int,
    val unlockCount: Int,
    val batteryPct: Int? = null,
)

/** Push-token registration for POST /v1/devices/<id>/push-token. */
data class PushTokenDto(
    val token: String,
)

/**
 * Alert creation payload for POST /v1/alerts/internal (HMAC-signed via X-FamilyShield-Signature).
 * [severity] is info|warning|critical; [category] matches the shared Alert category enum.
 */
data class AlertDto(
    val childId: String? = null,
    val deviceId: String? = null,
    val severity: String,
    val category: String,
    val title: String,
    val body: String,
    val metadata: Map<String, String> = emptyMap(),
)
