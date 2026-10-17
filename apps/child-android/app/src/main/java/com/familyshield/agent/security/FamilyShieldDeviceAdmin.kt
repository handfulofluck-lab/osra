package com.familyshield.agent.security

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Device Admin receiver (ADR-0010). Being an active admin is what lets the agent block uninstall
 * (the user must clear admin first, which we gate behind the parent PIN) and call `lockNow`.
 *
 * `onDisableRequested` returns the warning the OS shows when the child tries to turn admin off; the
 * PIN gate lives in the Settings flow we launch, not here (the OS cannot host a PIN prompt in this
 * callback). `onDisabled` fires after admin is actually removed — we record it so the next agent
 * poll raises a tamper alert to the parent.
 */
class FamilyShieldDeviceAdmin : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        Log.i(TAG, "device admin enabled")
        TamperState.setAdminDisabledPending(context, false)
    }

    override fun onDisableRequested(context: Context, intent: Intent): CharSequence =
        "Removing OSRA admin turns off the parental-control protections on this device. " +
            "Your parent will be notified."

    override fun onDisabled(context: Context, intent: Intent) {
        if (TamperState.isRemovalSanctioned(context, System.currentTimeMillis())) {
            Log.i(TAG, "device admin disabled by the parent (PIN verified) — no alert")
            TamperState.setLastTier(context, ProtectionTier.NONE.name)
            return
        }
        Log.w(TAG, "device admin disabled — flagging tamper alert")
        TamperState.setAdminDisabledPending(context, true)
        // Tell the parent now, not at the next poll: expedited work survives the process death that
        // usually follows an admin removal, and LocationService's 60-s loop is the fallback.
        runCatching { TamperAlertWorker.enqueue(context, TamperAlertWorker.TYPE_ADMIN_REMOVED) }
            .onFailure { Log.w(TAG, "could not enqueue tamper alert", it) }
    }

    private companion object {
        const val TAG = "FSDeviceAdmin"
    }
}
