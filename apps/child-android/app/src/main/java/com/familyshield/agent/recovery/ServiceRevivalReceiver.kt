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
        handleBroadcast(intent?.action) {
            ServiceRecovery.run(context.applicationContext)
        }
    }

    companion object {
        private const val TAG = "ServiceRevivalReceiver"

        internal fun handleBroadcast(
            action: String?,
            runRecovery: () -> ServiceRecoveryPolicy.Plan,
        ): ServiceRecoveryPolicy.Plan? {
            if (action != ServiceRevivalPolicy.ACTION_REVIVE_SERVICES) return null
            return runCatching { runRecovery() }
                .onFailure { Log.w(TAG, "service revival failed", it) }
                .getOrNull()
        }
    }
}
