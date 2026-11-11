package com.familyshield.agent.capabilities

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.familyshield.agent.BuildConfig
import com.familyshield.agent.network.ClientHeader
import com.familyshield.agent.security.DeviceAdminManager
import com.familyshield.agent.security.ProfileReader
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.setup.GrantChecks
import com.familyshield.agent.setup.OnboardingPolicy
import com.familyshield.agent.vpn.VpnState
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * ADR-0034 decision 1: gathers the facts [CapabilitiesPolicy] turns into the report, and nothing else.
 *
 * This class is the only Android-aware part: it asks the OS the same questions the setup screen asks, so a
 * parent who has just fixed a grant sees the report change for the same reason the checklist changed. The
 * decisions live in the policy, which is why every rule there is a JVM row and nothing here is.
 *
 * Two facts deserve their caveats:
 *
 * - **`tunnelRunning` is `VpnState.isEstablished`, not `FilterVpnService.isRunning`.** The latter means "the
 *   service object exists" — true from `onCreate`, before any tunnel (#234) — so it would report a filter that
 *   is not filtering as `ready`. `isEstablished` is a persisted flag that is cleared in `onDestroy`, so a process
 *   killed without one leaves it `true` and the report claims a tunnel that is gone **until the next start
 *   corrects it**; the alternative (asking the service) is not available from a report and would still be a
 *   snapshot. Worth revisiting if a phone is ever seen reporting `web_filter: ready` with the filter down.
 * - **`adminLocked` is `false`, deliberately.** It is the *result* of a `lockNow()` call, a per-command fact
 *   the dispatcher has and a capability check does not; `EnforceabilityPolicy.lockOutcome` does not use it in
 *   its verdict (the accessibility service is what holds the screen), so passing `false` changes nothing and
 *   pretending otherwise would be a lie in the signature.
 */
@Singleton
class CapabilityReporter @Inject constructor(
    @ApplicationContext private val context: Context,
    deviceAdmin: DeviceAdminManager,
) {

    private val grants = GrantChecks(context, deviceAdmin)
    private val profiles = ProfileReader(context)

    /** The report, or null when this build cannot name itself (see [CapabilitiesPolicy.report]). */
    fun report(): Map<String, Any?>? = CapabilitiesPolicy.report(
        versionName = BuildConfig.VERSION_NAME,
        versionCode = BuildConfig.VERSION_CODE,
        flavour = if (BuildConfig.CAPTURE_CALL_SMS) ClientHeader.FLAVOUR_FULL else ClientHeader.FLAVOUR_PLAY,
        facts = facts(),
    )

    /** What the phone looks like right now, re-read on every call — a cached verdict would go stale. */
    fun facts(): CapabilitiesPolicy.CapabilityFacts {
        val full = BuildConfig.CAPTURE_CALL_SMS
        return CapabilitiesPolicy.CapabilityFacts(
            versionName = BuildConfig.VERSION_NAME,
            versionCode = BuildConfig.VERSION_CODE,
            fullBuild = full,
            applicableGrants = CapabilitiesPolicy.GRANT_WIRE
                .filterTo(LinkedHashSet()) { it != "notification_listener" || full },
            grantedGrants = OnboardingPolicy.Grant.entries
                .filter { grants.isGranted(it) }
                .map { GrantWire.name(it) }
                .toSet(),
            accessibilityRunning = AccessibilityMonitorService.isRunning,
            canOverlay = Settings.canDrawOverlays(context),
            adminLocked = false,
            webFilterSetUp = grants.isGranted(OnboardingPolicy.Grant.WEB_FILTER),
            tunnelRunning = VpnState.isEstablished(context),
            backgroundLocation = hasBackgroundLocation(),
            callSmsGranted = full && hasPermission(Manifest.permission.READ_CALL_LOG) && hasPermission(Manifest.permission.READ_SMS),
            profiles = profiles.read(),
        )
    }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /**
     * "Allow all the time": below Android 10 there is one location permission, so the fine grant is the whole
     * of it; from 29 the background grant is separate and is what makes the feature work with the app closed.
     */
    private fun hasBackgroundLocation(): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            hasPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }

}
