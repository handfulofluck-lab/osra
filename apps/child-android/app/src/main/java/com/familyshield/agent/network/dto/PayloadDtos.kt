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
    /**
     * Issue #221 (D1): `background` | `while_in_use` | `none`, from
     * [com.familyshield.agent.telemetry.LocationGrantState]. Non-null and always sent: the server
     * uses it to fail a `locate_now` at once when no background fix is possible, instead of letting
     * it expire before WorkManager's 15-minute poll.
     */
    val locationGrant: String,
    /**
     * Issue #475: the rules version this agent has saved and applied, or null when it has never applied one
     * (a fresh install). Omitted rather than sent as 0, because null is "never reported" and the server
     * stores it as such.
     */
    val appliedRulesVersion: Int? = null,
)

/**
 * Push-token registration for `POST /v1/devices/<id>/push-token` (#319; the decided contract,
 * device-only, server half in PR #320).
 *
 * The field is `token` because that is the name `PushTokenSchema`
 * (`services/api/src/routes/devices.ts`) reads, and the value is the FCM registration token
 * (20–4096 characters). It was briefly `pushToken` while the client pointed at a different route;
 * that is a `400` against this schema, which is why `PushTokenRouteTest` pins the serialised JSON.
 */
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
    /**
     * Issue #199 item 5: whether Android treats this package as essential (dialer, HOME, the agent).
     * Computed here with [com.familyshield.agent.enforcement.EssentialPackages.isEssential] and
     * [com.familyshield.agent.enforcement.PackageFacts], because the phone is the only side that knows
     * the OS roles. The parent shows it; nothing enforces with it.
     */
    val essential: Boolean,
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
    /** Issue #225: makes a retried alert a no-op server-side instead of a second parent page. */
    val dedupeKey: String? = null,
    /**
     * Issue #227: the number of attempts this aggregate alert represents. When a later POST repeats
     * [dedupeKey] with a higher count, the server updates the existing row instead of inserting and
     * does not push again. Null (the default) keeps the #225 duplicate-is-a-no-op rule.
     */
    val attemptCount: Int? = null,
)
