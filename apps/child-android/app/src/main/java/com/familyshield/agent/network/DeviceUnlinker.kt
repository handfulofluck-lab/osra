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
        // Every step is guarded on its own: one failure must not skip the rest, or the phone is left in
        // a worse state than before the unlink (an unpaired phone still holding device admin).
        //
        // **The order changed after review, and the reason is a decision path.** Forgetting the rules
        // before clearing the pairing leaves a window where the phone is still *paired* with **no**
        // rules, and `RuleRepository.decide` answers BLOCK for every non-essential app in that state
        // (AND-03). If `clearPairing()` then threw — secure storage is the plausible way — the phone
        // would stay paired with null rules for good: every app blocked, no parent to fix it. Clearing
        // the pairing first makes the worse failure "unpaired, rules still on disk", which blocks only
        // what the deleted family had blocked and no longer blocks anything once the rules go.
        runCatching { FilterVpnService.stop(context) }
        runCatching { LockState.clear(context) }
        runCatching { settings.clearPairing() }
        runCatching { rules.forgetRules() }
        // The admin grant is the agent's own, and it removes itself: no Settings sheet, no PIN, because
        // the PIN belonged to a parent account that no longer exists.
        runCatching { admin.removeAdmin() }
        runCatching { UnlinkedNotice.show(context) }
        unlinked = true
    }
}
