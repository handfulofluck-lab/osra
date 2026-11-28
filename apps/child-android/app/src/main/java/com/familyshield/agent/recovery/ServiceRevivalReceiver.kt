package com.familyshield.agent.recovery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Internal (`android:exported="false"`) broadcast receiver woken by [ServiceRevivalScheduler] to
 * run [ServiceRecovery.run] immediately after task cleanup or unexpected service termination.
 */
class ServiceRevivalReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ServiceRevivalPolicy.ACTION_REVIVE_SERVICES) return
        runCatching { ServiceRecovery.run(context.applicationContext) }
            .onFailure { Log.w(TAG, "service revival failed", it) }
    }

    companion object {
        private const val TAG = "ServiceRevivalReceiver"
    }
}
