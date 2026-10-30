package com.familyshield.agent.network

import android.content.Context
import com.familyshield.agent.commands.LockActivity
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.security.DeviceAdminManager
import com.familyshield.agent.vpn.FilterVpnService
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Issue #465: what a phone does when the server says its family is gone.
 *
 * A deleted family's phone used to stay locked and enforcing forever: the poll threw on the
 * `401 device_revoked`, `clearPairing()` was reachable only from the PIN-gated Re-pair button, and the
 * device-admin grant came off only through the PIN-gated removal. Nobody could unpair it — the parent
 * account that would have, no longer exists — and the child cannot uninstall a device admin. Play
 * reviewers expect deleting an account to release the device, and a bereaved customer's phone staying
 * locked is the opposite of a deletion.
 *
 * The order matters and is the issue's:
 * 1. stop enforcing (rules, overlays, the VPN) — before anything else, so nothing re-raises;
 * 2. clear the pairing — from here the poller returns early and no request is made;
 * 3. drop device admin **without the PIN** — the agent removes its own grant, so no Settings sheet;
 * 4. tell the person holding the phone, in words they can act on.
 */
@Singleton
class DeviceUnlinker @Inject constructor(
    @ApplicationContext private val context: Context,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val admin: DeviceAdminManager,
) {

    /** True once this has run; the poller checks [UnlinkPolicy.isUnlinked] for the same fact. */
    @Volatile
    var unlinked: Boolean = false
        private set

    suspend fun unlink() {
        if (unlinked) return
        // 1. Stop enforcing. The VPN first: it is the one thing that keeps dropping packets while the
        // rest of this runs, and a later step can fail without leaving a filter behind.
        runCatching { FilterVpnService.stop(context) }
        LockState.clear(context)
        rules.forgetRules()
        // 2. Clear the pairing, so the poller stops talking to a server that no longer knows this phone.
        settings.clearPairing()
        // 3. Drop the admin grant without the PIN: the agent owns this grant and is removing itself.
        runCatching { admin.removeAdmin() }
        // 4. Say so on the device.
        UnlinkedNotice.show(context)
        unlinked = true
    }
}
