package com.familyshield.agent.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.WorkScheduler
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.services.PendingPingWorker

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        ContextCompat.startForegroundService(ctx, Intent(ctx, LocationService::class.java))
        WorkScheduler.scheduleAll(ctx)
        PendingPingWorker.schedule(ctx)
        // Plan 1.4: the web filter comes back with the phone (consent survives reboots; the tunnel does not).
        if (com.familyshield.agent.vpn.VpnState.isEnabled(ctx)) {
            runCatching { com.familyshield.agent.vpn.FilterVpnService.start(ctx) }
        }
        // Plan 1.3: a lock/pause the parent set before the reboot is still in force after it.
        val mode = com.familyshield.agent.enforcement.LockState.mode(ctx)
        if (com.familyshield.agent.enforcement.LockEnforcementPolicy.isLockingMode(mode)) {
            runCatching {
                ctx.startActivity(
                    Intent(ctx, com.familyshield.agent.commands.LockActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(com.familyshield.agent.commands.LockActivity.EXTRA_MODE, mode),
                )
            }
        }
    }
}
