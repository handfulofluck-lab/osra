package com.familyshield.agent.apps

import android.content.Context
import android.util.Log
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.enforcement.EssentialPackages
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.InstalledAppDto
import com.familyshield.agent.network.dto.InstalledAppsDto
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException

/**
 * Roadmap 3.4: uploads the installed-launchable-app inventory when it changes.
 *
 * Cadence — why it piggybacks on the telemetry worker instead of a new one. The list changes only
 * on install/uninstall/rename, which is rare, while a new periodic worker costs another wake-up,
 * another network constraint and another scheduler row on a battery-sensitive child device. The
 * existing 15-minute [com.familyshield.agent.telemetry.TelemetryWorker] already runs with
 * `NetworkType.CONNECTED`, so this reporter rides that tick and uploads only when the list's
 * fingerprint differs from the last successful upload. One forced refresh per [MAX_AGE_MS] keeps a
 * missed install broadcast or a stale server from staying wrong forever; an unchanged list costs a
 * local PackageManager query and no network.
 *
 * Privacy: the payload is the launcher-visible inventory only — package id, launcher label and the
 * system flag. No usage stats, no launch counts, no screen time, no icons. Consent withdrawal is
 * honoured here as it is in telemetry (`ConsentState.isPaused`), and the server re-checks with 428.
 */
@Singleton
class InstalledAppsReporter @Inject constructor(
    @ApplicationContext private val context: Context,
    private val api: ApiService,
    private val settings: AgentSettings,
    private val consent: ConsentState,
    /** Issue #199: the OS roles the essential set needs; injected so a test can feed a double. */
    private val facts: PackageFacts,
) {
    /** Uploads when the list changed, or when the last successful upload is older than 24 h. */
    suspend fun reportIfChanged(now: Long = System.currentTimeMillis()) {
        val deviceId = settings.deviceId() ?: return
        if (consent.isPaused()) return // ADR-0008 §3: no collection while consent is withdrawn

        val report = InstalledAppsCollector.collect(context)
        val hash = InstalledAppsPolicy.fingerprint(report.apps)
        val lastAt = settings.installedAppsReportedAt()
        val unchanged = hash == settings.installedAppsReportHash() &&
            lastAt != null && now - lastAt < MAX_AGE_MS
        if (unchanged) return
        if (report.truncated) Log.w(TAG, "installed app list reached the ${InstalledAppsPolicy.MAX_APPS}-app cap")

        try {
            api.postInstalledApps(
                deviceId,
                InstalledAppsDto(
                    version = CONTRACT_VERSION,
                    apps = report.apps.map {
                        inventoryApp(it.packageId, it.label, it.isSystem, facts)
                    },
                ),
            )
            // NOTE: the fingerprint moves only after the upload succeeds, so a failed POST is
            // retried on the next telemetry tick instead of being treated as already reported.
            settings.saveInstalledAppsReport(hash, now)
        } catch (e: CancellationException) {
            throw e // never swallow coroutine cancellation
        } catch (e: Exception) {
            Log.w(TAG, "installed app report failed", e)
        }
    }

    companion object {
        /** Maximum staleness of the server copy when the local list has not changed. */
        const val MAX_AGE_MS: Long = 24 * 60 * 60 * 1000L

        /** Contract version accepted by POST /v1/devices/:id/apps (zod `literal(1)`). */
        const val CONTRACT_VERSION: Int = 1

        private const val TAG = "InstalledAppsReporter"
    }
}

/**
 * Issue #199 item 5: one inventory row as the wire carries it, with `essential` computed where the OS
 * roles exist. Pure, so a JVM row can pin that the dialer leaves the phone as `essential = true` — the
 * parent cannot work that out from a package name, and the server must never guess.
 *
 * **A role change alone does not re-upload (#199 review).** The upload is gated on the list's
 * fingerprint (`InstalledAppsPolicy.fingerprint`), which covers package ids, labels and the system flag —
 * so the child making a different app the default dialer, with the same package list, keeps the old
 * `essential` values on the server until the forced 24-hour refresh
 * ([InstalledAppsReporter.MAX_AGE_MS]) picks them up. That is accepted because nothing enforces with this
 * field: the phone's own `EssentialPackages` answer decides, and the parent's copy is a label. If it ever
 * becomes enforcement, the fingerprint has to include the role answer first.
 */
internal fun inventoryApp(
    packageId: String,
    label: String,
    isSystem: Boolean,
    facts: PackageFacts,
): InstalledAppDto = InstalledAppDto(
    packageId = packageId,
    label = label,
    isSystem = isSystem,
    essential = EssentialPackages.isEssential(packageId, facts),
)
