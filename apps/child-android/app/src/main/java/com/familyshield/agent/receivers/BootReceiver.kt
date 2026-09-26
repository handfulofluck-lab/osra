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
    }
}
