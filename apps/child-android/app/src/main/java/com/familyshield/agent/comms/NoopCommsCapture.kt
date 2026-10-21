package com.familyshield.agent.comms

import javax.inject.Inject
import javax.inject.Singleton

/**
 * ADR-0021: what the Play build binds to [CommsCapture]. The Play artefact declares neither
 * `READ_CALL_LOG` nor `READ_SMS`, so there is nothing to capture and no observer to register —
 * this exists so the rest of the app does not have to know which flavour it is running in.
 */
@Singleton
class NoopCommsCapture @Inject constructor() : CommsCapture {
    override fun start() = Unit

    /** Issue #229: the Play build has no comms permission to re-check. */
    override fun onPermissionsChanged() = Unit

    override suspend fun flush() = Unit
}
