package com.familyshield.agent.recovery

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.commands.LockActivity
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.receivers.AccessibilityOffPolicy
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.services.LocationStartPolicy
import com.familyshield.agent.vpn.FilterVpnService
import com.familyshield.agent.vpn.VpnState
import dagger.hilt.android.EntryPointAccessors

/**
 * Issue #1085: re-establish what the OS took away, on the work tick that already exists.
 *
 * The phone's own cleaner kills the process (`OneKeyClean` on MIUI), the VPN unbinds and Android leaves the
 * accessibility service marked crashed. WorkManager is the one thing that still starts us — the 60-second
 * command poll and the 15-minute telemetry tick both begin a fresh process — so the recovery runs there
 * rather than on a new timer: nothing new to schedule, nothing new for the battery to pay, and it is exactly
 * the moment we learn that the last process died.
 *
 * Each step is isolated the way [com.familyshield.agent.receivers.BootReceiver] isolates its own: one failed
 * restart must not cost the next one. [ServiceRecoveryPolicy] decides *what* to do; this class only does it.
 */
object ServiceRecovery {

    private const val TAG = "ServiceRecovery"

    /**
     * Reads the device, decides, acts, and returns the gaps it saw. Safe to call on any worker tick: when
     * everything is already up the plan is empty and this costs a handful of in-process reads.
     */
    fun run(context: Context): ServiceRecoveryPolicy.Plan {
        val state = readState(context)
        val plan = ServiceRecoveryPolicy.plan(state)
        if (plan.isEmpty) return plan

        Log.i(TAG, "recovering after a restart: gaps=${plan.gaps}")
        if (plan.restartFilter) step("web filter") { FilterVpnService.start(context) }
        if (plan.restartLocation) step("location service") { startLocation(context) }
        if (plan.showLock) step("lock screen") { showLock(context, LockState.mode(context)) }
        return plan
    }

    /** The facts the policy needs. Split out so the mapping is readable and the policy stays pure. */
    internal fun readState(context: Context): ServiceRecoveryPolicy.State {
        val settings = EntryPointAccessors.fromApplication(context, WorkerEntryPoint::class.java).agentSettings()
        val isPaired = settings.isPairedSync()
        return ServiceRecoveryPolicy.State(
            isPaired = isPaired,
            consentPaused = EntryPointAccessors.fromApplication(context, WorkerEntryPoint::class.java).consentState().isPaused(),
            filterWanted = VpnState.isEnabled(context),
            // Hydrogen's #1098 review: `VpnState.isEstablished` is a persisted flag cleared only in
            // `onDestroy`, so after a kill it reads `true` for a tunnel that no longer exists and the filter
            // was never restarted. The in-process mode is null in a fresh process by construction.
            tunnelRunning = FilterVpnService.tunnelMode != null,
            // The same rule the background start sites use (issue #132), so this worker cannot be the one
            // site that starts LocationService with only a while-in-use grant on API 29+.
            locationMayStart = LocationStartPolicy.shouldStart(
                isPaired = isPaired,
                hasFineLocation = granted(context, Manifest.permission.ACCESS_FINE_LOCATION),
                hasCoarseLocation = granted(context, Manifest.permission.ACCESS_COARSE_LOCATION),
                hasBackgroundLocation = hasBackgroundLocation(context),
                apiLevel = Build.VERSION.SDK_INT,
            ),
            locationRunning = LocationService.isServiceRunning,
            lockActive = LockEnforcementPolicy.isLockingMode(LockState.mode(context)),
            accessibilityEnabled = accessibilityEnabled(context),
            // The in-process flag, which is false in a fresh process even while Settings still lists us.
            accessibilityBound = AccessibilityMonitorService.isRunning,
        )
    }

    /** "Allow all the time": below Android 10 the fine grant is the whole of it (same rule as the reporter). */
    private fun hasBackgroundLocation(context: Context): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            granted(context, Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }

    private fun startLocation(context: Context) {
        // Its own guard: `startForegroundService` obliges the service to reach `startForeground()`, and a
        // background-only grant is not enough to hold one (issue #128).
        ContextCompat.startForegroundService(context, Intent(context, LocationService::class.java))
    }

    private fun showLock(context: Context, mode: String) {
        // Android 10+ drops a background activity launch with neither the overlay app-op nor a bound
        // accessibility service (Hydrogen's #1098 review). Trying anyway would log a "recovery" that never
        // reached the screen; the gap stays in the plan either way.
        val canLaunch = Settings.canDrawOverlays(context) || AccessibilityMonitorService.isRunning
        if (!canLaunch) {
            Log.w(TAG, "lock screen not shown: no overlay app-op and no bound accessibility service")
            return
        }
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                .putExtra(LockActivity.EXTRA_MODE, mode),
        )
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /**
     * Whether our accessibility service is switched on: the global switch **and** our component, parsed by
     * the shared rule rather than a hand-rolled split (Hydrogen's #1098 review — the old split missed the
     * `pkg/.Class` form and the global switch entirely).
     *
     * Being switched on is not being bound; [AccessibilityMonitorService.isRunning] answers that, and the
     * two together are what separate `ACCESSIBILITY_OFF` from `ACCESSIBILITY_UNBOUND`.
     */
    private fun accessibilityEnabled(context: Context): Boolean {
        val resolver = context.contentResolver
        return AccessibilityOffPolicy.isEffectivelyEnabled(
            accessibilityEnabled = Settings.Secure.getString(resolver, Settings.Secure.ACCESSIBILITY_ENABLED),
            enabledServices = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES),
            component = "${context.packageName}/${AccessibilityMonitorService::class.java.name}",
        )
    }

    private fun step(name: String, block: () -> Unit) {
        runCatching(block).onFailure { Log.e(TAG, "recovery step failed: $name", it) }
    }
}
