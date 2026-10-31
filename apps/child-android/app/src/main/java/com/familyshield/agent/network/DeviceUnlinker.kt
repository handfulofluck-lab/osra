package com.familyshield.agent.network

import android.content.Context
import android.content.Intent
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.security.DeviceAdminManager
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.vpn.FilterVpnService
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/** One step of an unlink, named so a row can assert the order rather than the wording of a comment. */
internal data class UnlinkStep(val name: String, val run: suspend () -> Unit)

/**
 * Issue #465 review: the unlink **sequence**, pulled out of the Android object so the JVM suite can run it.
 *
 * The sequence is the whole correctness argument, so leaving it untested was the defect: `UnlinkOrderTest`
 * called `RuleRepository.decide` and `UnlinkPolicy` and never touched the unlinker, so swapping two steps
 * back changed nothing in the suite.
 *
 * - **Every step is guarded on its own.** One failure must not skip the rest, or the phone is left worse
 *   than before — an unpaired phone still holding device admin.
 * - **The pending flag is written first and cleared last, and only on full success.** If any step threw, or
 *   the admin grant is still active afterwards, the flag stays set and the next start runs the whole
 *   sequence again; every step is idempotent, so re-running is safe.
 */
internal suspend fun runUnlinkSteps(
    steps: List<UnlinkStep>,
    markPending: suspend () -> Unit,
    clearPending: suspend () -> Unit,
    isAdminActive: () -> Boolean,
    onFailure: (UnlinkStep, Throwable) -> Unit = { _, _ -> },
): Boolean {
    runCatching { markPending() }
    var allSucceeded = true
    for (step in steps) {
        runCatching { step.run() }.onFailure { failure ->
            allSucceeded = false
            onFailure(step, failure)
        }
    }
    val done = allSucceeded && !isAdminActive()
    if (done) runCatching { clearPending() }
    return done
}

/**
 * Issue #465 review: the **production** step list, in one place, so a row can assert the order the phone
 * actually runs instead of the order a test wrote down for itself. Swapping two steps here turns U5 red;
 * the first version of these rows built its own list, which is why the swap survived.
 */
internal fun buildUnlinkSteps(
    stopVpn: suspend () -> Unit,
    clearLock: suspend () -> Unit,
    // Issue #472 review: the service that is already running is the one that polls, so it is the one
    // that saw the 401. Stopping it before the pairing is cleared means no poll can run in the window
    // between "no device id" and "service gone".
    stopLocation: suspend () -> Unit,
    clearPairing: suspend () -> Unit,
    forgetRules: suspend () -> Unit,
    removeAdmin: suspend () -> Unit,
    notify: suspend () -> Unit,
): List<UnlinkStep> = listOf(
    // The VPN first: it is the one thing still dropping packets while the rest runs.
    UnlinkStep("vpn", stopVpn),
    UnlinkStep("lock", clearLock),
    UnlinkStep("location", stopLocation),
    // Pairing before rules: a paired phone with no rules blocks every app (AND-03).
    UnlinkStep("pairing", clearPairing),
    UnlinkStep("rules", forgetRules),
    // The admin grant is the agent's own; it removes itself, because the PIN belonged to a parent
    // account that no longer exists.
    UnlinkStep("admin", removeAdmin),
    UnlinkStep("notice", notify),
)

/**
 * Issue #465: what a phone does when the server says its family is gone.
 *
 * A deleted family's phone used to stay locked and enforcing forever: the poll threw on the
 * `401 device_revoked`, `clearPairing()` was reachable only from the PIN-gated Re-pair button, and the
 * device-admin grant came off only through the PIN-gated removal. Nobody could unpair it — the parent
 * account that would have, no longer exists — and the child cannot uninstall a device admin. Play
 * reviewers expect deleting an account to release the device.
 *
 * The order is [runUnlinkSteps]'s, and the reason the pairing goes **before** the rules is
 * `RuleRepository.decide`: a phone that is still *paired* with **no** rules answers BLOCK for every
 * non-essential app (AND-03). Forgetting the rules first would leave that window, and a throw from
 * `clearPairing()` would have made it permanent — every app blocked, no parent to fix it.
 */
@Singleton
class DeviceUnlinker @Inject constructor(
    @ApplicationContext private val context: Context,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val admin: DeviceAdminManager,
) {

    /** True once this has run in this process; [UnlinkPolicy.isUnlinked] is the durable answer. */
    @Volatile
    var unlinked: Boolean = false
        private set

    suspend fun unlink() {
        if (unlinked) return
        runUnlinkSteps(
            steps = buildUnlinkSteps(
                stopVpn = { FilterVpnService.stop(context) },
                clearLock = { LockState.clear(context) },
                stopLocation = { context.stopService(Intent(context, LocationService::class.java)) },
                clearPairing = { settings.clearPairing() },
                forgetRules = { rules.forgetRules() },
                removeAdmin = { admin.removeAdmin() },
                notify = { UnlinkedNotice.show(context) },
            ),
            markPending = { settings.setUnlinkPending(true) },
            clearPending = { settings.setUnlinkPending(false) },
            isAdminActive = { admin.isAdminActive() },
        )
        unlinked = true
    }
}
