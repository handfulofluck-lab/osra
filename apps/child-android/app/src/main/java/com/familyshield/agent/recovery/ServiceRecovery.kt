package com.familyshield.agent.recovery

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.commands.LockActivity
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.services.LocationService
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
        val filterWanted = VpnState.isEnabled(context)
        return ServiceRecoveryPolicy.State(
            isPaired = settings.isPairedSync(),
            consentPaused = EntryPointAccessors.fromApplication(context, WorkerEntryPoint::class.java).consentState().isPaused(),
            filterWanted = filterWanted,
            tunnelRunning = VpnState.isEstablished(context),
            locationGrantHeld = granted(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
                granted(context, Manifest.permission.ACCESS_COARSE_LOCATION),
            locationRunning = LocationService.isServiceRunning,
            lockActive = LockEnforcementPolicy.isLockingMode(LockState.mode(context)),
            accessibilityEnabled = accessibilityEnabled(context),
        )
    }

    private fun startLocation(context: Context) {
        // Its own guard: `startForegroundService` obliges the service to reach `startForeground()`, and a
        // background-only grant is not enough to hold one (issue #128).
        ContextCompat.startForegroundService(context, Intent(context, LocationService::class.java))
    }

    private fun showLock(context: Context, mode: String) {
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, mode),
        )
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /**
     * Whether our accessibility service is switched on in Settings — **not** whether it is bound.
     *
     * Android has no public way to ask "is this service currently bound", and MIUI's kill leaves ours
     * *enabled* while marking it crashed (`dumpsys`: `Enabled services: {…}`, `Crashed services: {…}`), so this
     * check cannot see the very state #1085 is about. It is kept because "off" is still worth reporting, and
     * the PR says plainly that "crashed" is detected by the absence of scan traffic, not from here.
     */
    private fun accessibilityEnabled(context: Context): Boolean {
        val expected = "${context.packageName}/${com.familyshield.agent.services.AccessibilityMonitorService::class.java.name}"
        val enabled = android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ).orEmpty()
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    private fun step(name: String, block: () -> Unit) {
        runCatching(block).onFailure { Log.e(TAG, "recovery step failed: $name", it) }
    }
}
