package com.familyshield.agent.update

import javax.inject.Inject
import javax.inject.Singleton

/**
 * ADR-0039 D5.1: "every 12 h, plus once at boot and after pairing". The trigger points (`BootReceiver`,
 * the end of pairing) live in `main` and must not name the Full worker, so they call this interface; the
 * `full` flavour binds `FullUpdateWorker`'s schedule through it and `play` binds
 * [NoopUpdateCheckScheduler].
 */
interface UpdateCheckScheduler {
    /** Enqueues the 12 h periodic check; `KEEP`, so calling it on every boot is idempotent. */
    fun schedulePeriodic()

    /** Enqueues one immediate check. */
    fun checkNow()
}

/** What the Play build binds: Google Play updates that artefact, so it must never install anything. */
@Singleton
class NoopUpdateCheckScheduler @Inject constructor() : UpdateCheckScheduler {
    override fun schedulePeriodic() = Unit

    override fun checkNow() = Unit
}
