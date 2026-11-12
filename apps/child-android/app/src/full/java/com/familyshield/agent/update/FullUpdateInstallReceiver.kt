package com.familyshield.agent.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The Full install session's status callback (ADR-0039 D5.4). All of the work, including the status
 * extras, is [FullUpdater.onInstallStatus]'s, so the installer API is still named by one class only
 * (amendment row 5); only the Full manifest declares this receiver.
 */
class FullUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = FullUpdater.onInstallStatus(context, intent)
}
