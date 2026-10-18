package com.familyshield.agent.receivers

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.commands.LockActivity
import com.familyshield.agent.data.WorkScheduler
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.services.PendingPingWorker
import com.familyshield.agent.vpn.FilterVpnService
import com.familyshield.agent.vpn.VpnState

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        // Issue #128: each step is isolated. A crashing receiver is the one failure that can also
        // cost the next boot its protection, so a failed step is logged and the rest still run.
        guardStep("location service") { startLocationIfPermitted(ctx) }
        guardStep("scheduled work") {
            WorkScheduler.scheduleAll(ctx)
            PendingPingWorker.schedule(ctx)
        }
        // Plan 1.4: the web filter comes back with the phone (consent survives reboots; the tunnel does not).
        guardStep("web filter") {
            if (VpnState.isEnabled(ctx)) FilterVpnService.start(ctx)
        }
        // Plan 1.3: a lock/pause the parent set before the reboot is still in force after it.
        guardStep("lock screen") {
            val mode = LockState.mode(ctx)
            if (LockEnforcementPolicy.isLockingMode(mode)) {
                ctx.startActivity(
                    Intent(ctx, LockActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(LockActivity.EXTRA_MODE, mode),
                )
            }
        }
    }

    /**
     * Issue #128: never request a location FGS the app cannot hold. `startForegroundService()`
     * obliges the service to reach `startForeground()`; `LocationService` declines when the
     * permission is missing, stops itself, and the system then throws
     * `ForegroundServiceDidNotStartInTimeException` in this receiver.
     */
    private fun startLocationIfPermitted(ctx: Context) {
        val hasFine = granted(ctx, Manifest.permission.ACCESS_FINE_LOCATION)
        val hasCoarse = granted(ctx, Manifest.permission.ACCESS_COARSE_LOCATION)
        val hasBackground = granted(ctx, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        if (!BootStartPolicy.shouldStartLocationService(hasFine, hasCoarse, hasBackground, Build.VERSION.SDK_INT)) {
            Log.i(
                TAG,
                "location not granted (fine=$hasFine coarse=$hasCoarse background=$hasBackground); not starting LocationService at boot",
            )
            return
        }
        ContextCompat.startForegroundService(ctx, Intent(ctx, LocationService::class.java))
    }

    private fun granted(ctx: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

    private fun guardStep(name: String, block: () -> Unit) {
        runCatching(block).onFailure { Log.e(TAG, "boot step failed: $name", it) }
    }

    companion object {
        private const val TAG = "BootReceiver"
    }
}
