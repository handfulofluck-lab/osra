package com.familyshield.agent.security

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Android façade over [DevicePolicyManager] and the tamper state (ADR-0010). All the pure decisions
 * live in [TamperPolicy]; this class only reads the OS and performs the privileged calls.
 */
@Singleton
class DeviceAdminManager @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val dpm: DevicePolicyManager
        get() = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    /** Reflection-only: null on every non-Samsung device and after any Knox failure (issue #186). */
    private val knoxCapability: KnoxAdminApi? by lazy { KnoxAdminCapability.probe(context, adminComponent) }
    private val removalPolicy = AdminRemovalPolicy { knoxCapability }

    val adminComponent: ComponentName
        get() = ComponentName(context, GuardianAdminReceiver::class.java)

    /** True when Samsung's Knox admin API is usable, so removal must not rely on AOSP alone. */
    val hasKnoxAdminApi: Boolean
        get() = knoxCapability != null

    /**
     * True when this app removed its own admin through the parent-PIN flow and no activation has
     * succeeded since (issue #188). A deliberate removal is not a stuck Knox record, and the status
     * screen must not say it is.
     */
    val wasAdminRemovedByParent: Boolean
        get() = TamperState.wasAdminRemovedByParent(context)

    fun isAdminActive(): Boolean = dpm.isAdminActive(adminComponent)

    fun isDeviceOwner(): Boolean = dpm.isDeviceOwnerApp(context.packageName)

    fun tier(): ProtectionTier = TamperPolicy.tierOf(isAdminActive(), isDeviceOwner())

    /**
     * Classifies an activation attempt after the system sheet returned. Call with `false` while the
     * sheet is still open. [alreadyAddedRefusal] is the observed "Admin is already added" shape from
     * [AdminEnrolmentPolicy.isAlreadyAddedRefusal]; a successful activation clears the parent-removal
     * memory (issue #188).
     */
    fun enrolmentOutcome(sheetReturned: Boolean, alreadyAddedRefusal: Boolean = false): EnrolmentOutcome {
        val outcome = AdminEnrolmentPolicy.classify(
            sheetReturned = sheetReturned,
            isAdminActive = isAdminActive(),
            isDeviceOwner = isDeviceOwner(),
            knoxAvailable = hasKnoxAdminApi,
            alreadyAddedRefusal = alreadyAddedRefusal,
        )
        if (AdminEnrolmentPolicy.clearsParentRemoval(outcome)) {
            TamperState.setAdminRemovedByParent(context, false)
        }
        return outcome
    }

    /** Intent that opens the OS "activate device admin" screen. Launched from the onboarding wizard. */
    fun requestAdminIntent(): Intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
        putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent)
        putExtra(
            DevicePolicyManager.EXTRA_ADD_EXPLANATION,
            "OSRA needs device-admin rights to stop this app being uninstalled and to lock the device " +
                "when your parent asks.",
        )
    }

    /**
     * Applies the strongest uninstall protection the current tier allows. On a device owner this is an
     * outright OS block; on a plain admin the OS offers no uninstall block, so protection is the PIN
     * gate on clearing admin plus the tamper alert. Returns the tier actually in force.
     */
    fun applyUninstallProtection(): ProtectionTier {
        val tier = tier()
        if (tier == ProtectionTier.OWNER) {
            runCatching { dpm.setUninstallBlocked(adminComponent, context.packageName, true) }
                .onFailure { Log.w(TAG, "setUninstallBlocked failed", it) }
        }
        return tier
    }

    /** Locks the screen immediately when admin/owner allows it. Returns false if the OS refused. */
    fun lockNow(): Boolean = runCatching {
        if (isAdminActive() || isDeviceOwner()) {
            dpm.lockNow(); true
        } else {
            false
        }
    }.getOrDefault(false)

    /**
     * Clears admin after the parent PIN was verified (the only sanctioned way off the device). The OS
     * removal screen is the child-facing path and is gated by [GuardianAdminReceiver.onDisableRequested]'s
     * warning; this method is for the in-app "remove protection" flow behind the PIN.
     *
     * On Samsung, activation goes through Knox and Knox keeps its own admin registry; AOSP
     * `removeActiveAdmin` alone leaves a row that makes the next sheet activation fail with
     * `Admin is already added` (issue #186). [AdminRemovalPolicy] uses Knox when it is present and
     * keeps AOSP for every other device, so behaviour is unchanged off Samsung. A removal that
     * actually cleared the admin records itself as parent-initiated (issue #188).
     */
    fun removeAdmin(): AdminRemovalRoute {
        TamperState.markSanctionedRemoval(context, System.currentTimeMillis() + 60_000L)
        TamperState.setLastTier(context, ProtectionTier.NONE.name)
        val route = removalPolicy.remove(
            adminStillActive = { isAdminActive() },
            aospRemove = {
                runCatching { if (isAdminActive()) dpm.removeActiveAdmin(adminComponent) }
                    .onFailure { Log.w(TAG, "removeActiveAdmin failed", it) }
            },
        )
        if (!isAdminActive()) TamperState.setAdminRemovedByParent(context, true)
        Log.i(TAG, "protection removed via $route")
        return route
    }

    /** True when the admin was disabled out-of-band and the parent has not yet been alerted. */
    fun consumeAdminDisabledAlert(): Boolean {
        val pending = TamperState.isAdminDisabledPending(context)
        if (pending) TamperState.setAdminDisabledPending(context, false)
        return pending
    }

    private companion object {
        const val TAG = "DeviceAdminManager"
    }
}
