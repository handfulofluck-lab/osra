package com.familyshield.agent.update

import javax.inject.Inject
import javax.inject.Singleton

/**
 * ADR-0039 D5.1: "every 12 h, plus once at boot and after pairing". The trigger points (`BootReceiver`,
 * the end of pairing) live in `main` and must not name the Full worker, so they call this interface; the
 * `full` flavour binds `FullUpdateWorker`'s schedule through it and `play` binds
 * [NoopUpdateCheckScheduler].
 *
 * This file is deliberately the only thing left in `com.familyshield.agent.update` under `src/main/`: the
 * four `main` callers ([com.familyshield.agent.FamilyShieldApp], `BootReceiver`, `PairingActivity`,
 * `WorkerEntryPoint`) need the seam, and everything else moved to `src/full/`, where the Play build cannot
 * compile it. A new `main` type that needs anything else from `update/` is the mistake this shape exists to
 * catch — keep it here only if the Play build genuinely needs it, and say why.
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
