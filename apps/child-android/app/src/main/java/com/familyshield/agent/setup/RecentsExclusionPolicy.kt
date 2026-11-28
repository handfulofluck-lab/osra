package com.familyshield.agent.setup

/**
 * Pure policy deciding when [PairingActivity]'s task should exclude itself from Android Recents
 * (osra-security#78).
 *
 * While onboarding is still in progress (`!paired || !setupCompletedOnce`), the task remains in
 * Recents so a parent switching between Settings and OSRA can return naturally. Once paired and
 * setup is complete, excluding the launcher task from Recents prevents accidental or OEM Recents
 * task-cleaner termination when closed.
 */
object RecentsExclusionPolicy {
    fun shouldExcludeFromRecents(paired: Boolean, setupCompletedOnce: Boolean): Boolean =
        paired && setupCompletedOnce
}
