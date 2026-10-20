package com.familyshield.agent.network

import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.network.dto.BlocklistPackDto
import com.familyshield.agent.network.dto.CommandAckDto
import com.familyshield.agent.network.dto.DeviceCommandDto
import com.familyshield.agent.network.dto.InstalledAppsDto
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.PushTokenDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SocialScanDto
import com.familyshield.agent.network.dto.TelemetryDto
import com.familyshield.agent.network.dto.ActivityEventBatchDto
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

/** Retrofit API surface used by the child agent. */
interface ApiService {

    /** Fetches the child's current rule set. */
    @GET("v1/rules/{childId}")
    suspend fun getRules(@Path("childId") childId: String): RuleSetDto

    /** Creates an alert; HMAC-signed by SignatureInterceptor. */
    @POST("v1/alerts/internal")
    suspend fun postInternalAlert(@Body alert: AlertDto)

    /** Uploads a batch of location pings (device-authenticated). */
    @POST("v1/location/ping")
    suspend fun postLocationPings(@Body batch: LocationPingBatchDto)

    /** Uploads an aggregated usage delta for a device. */
    @POST("v1/devices/{id}/telemetry")
    suspend fun postTelemetry(@Path("id") deviceId: String, @Body telemetry: TelemetryDto)

    /**
     * Roadmap 3.4: replaces this device's installed-launchable-app inventory. Device JWT, self-scoped
     * by the server (`requireOwnDevice`); a replace, not a merge, so uninstalled apps disappear.
     */
    @POST("v1/devices/{id}/apps")
    suspend fun postInstalledApps(@Path("id") deviceId: String, @Body body: InstalledAppsDto)

    /** Registers a new FCM push token for a device. */
    @POST("v1/devices/{id}/push-token")
    suspend fun postPushToken(@Path("id") deviceId: String, @Body body: PushTokenDto)

    /**
     * Drains pending parent commands (FCM-free polling fallback, §14.2).
     *
     * Issue #231: `ack=1` declares this agent ack-capable, which is what makes the server re-offer a
     * `delivered`-but-unacked row after 120 s (up to three attempts). Without it, a command whose
     * ack was lost — `locate_now` with a failed upload deliberately sends none — would stay
     * `delivered` forever, which is the defect #231 exists to remove.
     */
    @GET("v1/devices/{id}/commands")
    suspend fun getCommands(
        @Path("id") deviceId: String,
        @Query("ack") ackCapable: Int = ACK_CAPABLE,
    ): List<DeviceCommandDto>

    /**
     * Reports the outcome of one delivered command (Phase 2b). Issue #132: a `locate_now` the agent
     * refuses for a missing grant must reach the parent's `/commands/history` as `failed`, not stay
     * `delivered` forever or vanish.
     */
    @POST("v1/devices/{id}/commands/{commandId}/ack")
    suspend fun ackCommand(
        @Path("id") deviceId: String,
        @Path("commandId") commandId: String,
        @Body body: CommandAckDto,
    )

    /** Fetches the default blocklist pack (device JWT or parent, Feature #1). */
    @GET("v1/blocklists")
    suspend fun getBlocklists(): BlocklistPackDto

    /** Scans one redacted social/chat capture (Feature #2/#17); server raises alerts on flags. */
    @POST("v1/social/scan")
    suspend fun postSocialScan(@Body scan: SocialScanDto)

    /** Uploads a batch of call/SMS (Feature #6) or app_usage live-activity (Feature #29) events (device JWT). */
    @POST("v1/devices/{id}/activity")
    suspend fun postActivityEvents(@Path("id") deviceId: String, @Body batch: ActivityEventBatchDto)
}

/** `ack=1` on the command poll: this build acks every command it is given (issue #231). */
private const val ACK_CAPABLE = 1
