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
 *
 * The class name is itself operationally significant (issues #202 and #217): Samsung Knox keys its
 * admin registry by **component + user**, and a stale row for a previous component name refuses every
 * new activation through the system sheet with `Admin is already added`. A new component name is not in
 * that registry, so renaming the receiver is the recovery path — and the reason [COMPONENT_CLASS], the
 * manifest entry and `res/xml/device_admin.xml`'s consumer must move together.
 * `AdminReceiverContractTest` pins that.
 *
 * Renamed twice for the same reason: #209 moved `FamilyShieldDeviceAdmin` → `ParentalAdminReceiver`,
 * and #217 moved `ParentalAdminReceiver` → `GuardianAdminReceiver` after `dpm remove-active-admin`
 * stranded a Knox row on the Flip4. The root cause is the cleanup command, not the name — see
 * `docs/TESTING.md` §5, which no longer prescribes that command on a Samsung.
 */
class GuardianAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        Log.i(TAG, "device admin enabled")
        TamperState.setAdminDisabledPending(context, false)
        // A re-activation starts a new event; the next disable records its own timestamp.
        TamperState.setAdminDisabledAt(context, 0L)
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
        // Issue #225: the timestamp is the event identity. Both this enqueue and the 60-s drain
        // derive the same dedupe key from it, so one deactivation posts one alert.
        val disabledAtMs = System.currentTimeMillis()
        Log.w(TAG, "device admin disabled — flagging tamper alert ($disabledAtMs)")
        TamperState.setAdminDisabledAt(context, disabledAtMs)
        TamperState.setAdminDisabledPending(context, true)
        // Tell the parent now, not at the next poll: expedited work survives the process death that
        // usually follows an admin removal, and LocationService's 60-s loop is the fallback.
        runCatching { TamperAlertWorker.enqueue(context, TamperAlertWorker.TYPE_ADMIN_REMOVED, eventAtMs = disabledAtMs) }
            .onFailure { Log.w(TAG, "could not enqueue tamper alert", it) }
    }

    companion object {
        /**
         * The device-admin component's fully qualified class name — the one code-side place that spells
         * it. The manifest and the hardware scripts still name the component; the JVM contract test
         * resolves their relative names against the manifest namespace and fails if either drifts
         * (issue #202).
         */
        val COMPONENT_CLASS: String = GuardianAdminReceiver::class.java.name

        private const val TAG = "FSDeviceAdmin"
    }
}
