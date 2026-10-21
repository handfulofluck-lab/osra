package com.familyshield.agent.comms

/**
 * Issue #229: whether a call/SMS `ContentObserver` should be registered right now.
 *
 * `CommsLogger.start()` used to set one `started = true` before registering either observer. On the
 * Flip4 the call-log provider refuses `registerContentObserver` without `READ_CALL_LOG` (a
 * `SecurityException`), so the flag stayed set while the observer was absent and a later grant did
 * nothing until the process restarted. Each stream now has its own flag, and this pure decision owns
 * "register only a stream whose permission is granted and that has no observer yet".
 *
 * An observer that is already registered is left alone: registration is process-local and survives a
 * permission change, so re-registering it would deliver every change twice. A revoked permission is
 * handled at the harvest (`CommsAccessPolicy`), not by unregistering here.
 */
object CommsObserverPolicy {

    fun shouldRegister(permissionGranted: Boolean, alreadyRegistered: Boolean): Boolean =
        permissionGranted && !alreadyRegistered
}
