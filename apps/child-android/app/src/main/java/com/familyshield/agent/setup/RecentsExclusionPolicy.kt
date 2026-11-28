package com.familyshield.agent.setup

/**
 * Pure policy deciding when [PairingActivity]'s task should exclude itself from Android Recents
 * (osra-security#78).
 *
 * Scoped strictly to Xiaomi/Redmi/POCO (`MIUI` / `HyperOS`), where Recents cleanup invokes
 * `OneKeyClean` against listed tasks; Samsung, Pixel, and other vendors keep their existing
 * manifest-default Recents behaviour. Even on Xiaomi, onboarding (`!paired || !setupCompletedOnce`)
 * stays visible in Recents so a parent switching between Settings and OSRA can return naturally.
 */
object RecentsExclusionPolicy {
    fun shouldExcludeFromRecents(
        manufacturer: String?,
        paired: Boolean,
        setupCompletedOnce: Boolean,
    ): Boolean = MiuiBackgroundPopupPolicy.isXiaomiFamily(manufacturer) && paired && setupCompletedOnce
}
