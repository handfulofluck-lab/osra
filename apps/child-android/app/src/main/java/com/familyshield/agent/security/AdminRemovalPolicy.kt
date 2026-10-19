package com.familyshield.agent.security

/** The OS API that removed the device admin. */
enum class AdminRemovalRoute {
    /** Samsung's Knox enterprise admin API. */
    KNOX,

    /** AOSP `DevicePolicyManager.removeActiveAdmin`. */
    AOSP,
}

/**
 * The part of the Knox admin API the agent needs: deactivate **our own** component. It is an
 * interface so the removal decision stays free of reflection and Android types, and a test can
 * inject a probe that reports Knox present, absent, refusing or throwing.
 */
interface KnoxAdminApi {
    /** Deactivates the component through Knox. Returns false when the API refused the call. */
    fun deactivate(): Boolean
}

/** Supplies a Knox API handle, or null when this device has no usable Knox admin API. */
fun interface KnoxCapabilityProbe {
    fun knoxAdmin(): KnoxAdminApi?
}

/**
 * Chooses how an in-app protection removal leaves the device (ADR-0010, issue #186).
 *
 * Samsung activates through Knox, and Knox keeps an admin registry of its own. AOSP
 * `removeActiveAdmin` clears only the AOSP view, so a removal that ignores Knox can leave a row
 * that makes the next system-sheet activation fail with `Admin is already added`. When the probe
 * reports a usable Knox API, removal therefore goes through Knox first; every other case — another
 * OEM, the class missing, a refused call, a throwing probe — falls back to the AOSP call, which is
 * exactly the behaviour before #186.
 */
class AdminRemovalPolicy(private val knoxCapability: KnoxCapabilityProbe) {

    /** The route [remove] will prefer, for logging and diagnostics. */
    fun route(): AdminRemovalRoute = if (knoxOrNull() != null) AdminRemovalRoute.KNOX else AdminRemovalRoute.AOSP

    /**
     * Runs [aospRemove] unless Knox deactivated the component and [adminStillActive] confirms the
     * AOSP view is now clean. Returns the route that finished the removal.
     */
    fun remove(adminStillActive: () -> Boolean, aospRemove: () -> Unit): AdminRemovalRoute {
        val knox = knoxOrNull()
        if (knox != null) {
            val deactivated = runCatching { knox.deactivate() }.getOrDefault(false)
            if (deactivated && !adminStillActive()) return AdminRemovalRoute.KNOX
        }
        aospRemove()
        return AdminRemovalRoute.AOSP
    }

    private fun knoxOrNull(): KnoxAdminApi? =
        runCatching { knoxCapability.knoxAdmin() }.getOrNull()
}
