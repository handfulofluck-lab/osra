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
 * Roadmap 3.4: one installed-launchable app for POST /v1/devices/<id>/apps. The wire payload carries
 * no icon, usage or launch data — package, launcher label and the OS system flag are the whole
 * inventory. The server caps the same values (500 apps, 100-character labels).
 */
data class InstalledAppDto(
    val packageId: String,
    val label: String,
    val isSystem: Boolean,
)

/** Replace-wholesale inventory report for POST /v1/devices/<id>/apps (`version` is the contract). */
data class InstalledAppsDto(
    val version: Int,
    val apps: List<InstalledAppDto>,
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
