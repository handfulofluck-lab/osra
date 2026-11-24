package com.familyshield.agent.recovery

/**
 * Issue #1085: what the app should re-establish after the OS killed it.
 *
 * MIUI's `OneKeyClean` killed `com.osratech.child.full` outright; the VPN unbinds, Android marks the
 * accessibility service **crashed** and never rebinds it, and because nothing in the process is running no
 * overlay is re-launched either. WorkManager still starts the process on its next periodic tick — that is
 * the one thing the OS does for us — but until this policy existed, waking up changed nothing: the worker
 * uploaded telemetry and went back to sleep with the tunnel, the lock screen and the listener still down.
 *
 * Pure and Android-free so the decision is a JVM row. It answers two questions and nothing else:
 * which recoveries to attempt, and which gaps are worth telling the parent about. A phone that is unpaired
 * or paused answers "none" to both — restarting a tunnel on a de-linked device would be a bug, not a rescue.
 */
object ServiceRecoveryPolicy {

    /** What the device looks like right now, as far as the caller can tell without asking the OS twice. */
    data class State(
        val isPaired: Boolean,
        val consentPaused: Boolean,
        /** The parent asked for the web filter (`VpnState.isEnabled`). */
        val filterWanted: Boolean,
        /** The tunnel is actually carrying traffic. */
        val tunnelRunning: Boolean,
        /** Fine or coarse location is granted, so a location foreground service may legally start. */
        val locationGrantHeld: Boolean,
        /** `LocationService.isServiceRunning`. */
        val locationRunning: Boolean,
        /** True when `LockState` says a lock is in force. */
        val lockActive: Boolean,
        /**
         * Our accessibility service is switched on in Settings. Note what this is **not**: Android has no
         * public "is it bound" query, and a MIUI kill leaves it enabled while marking it crashed — so a
         * crashed-but-enabled service reads as `true` here. The crash is detected by the absence of scan
         * traffic, not by this flag; see ServiceRecovery's note.
         */
        val accessibilityEnabled: Boolean,
    )

    /** One thing that is down and worth naming. Recoverable gaps have a restart action; the last does not. */
    enum class Gap {
        /** The tunnel the parent asked for is not carrying traffic. */
        FILTER_DOWN,

        /** A location service that should be running is not. */
        LOCATION_DOWN,

        /** A lock is in force but nothing is showing it. */
        LOCK_NOT_SHOWN,

        /**
         * The accessibility service is switched off. Android will not start it for us, so this is reported
         * rather than restarted — claiming otherwise would be a lie a parent could not check.
         */
        ACCESSIBILITY_OFF,
    }

    data class Plan(
        val restartFilter: Boolean,
        val restartLocation: Boolean,
        val showLock: Boolean,
        val gaps: List<Gap>,
    ) {
        val isEmpty: Boolean get() = !restartFilter && !restartLocation && !showLock && gaps.isEmpty()
    }

    fun plan(state: State): Plan {
        // A de-linked phone has no family to protect: nothing to restart, nothing to report (issue #472).
        if (!state.isPaired || state.consentPaused) return Plan(false, false, false, emptyList())

        val restartFilter = state.filterWanted && !state.tunnelRunning
        val restartLocation = state.locationGrantHeld && !state.locationRunning
        val showLock = state.lockActive
        val gaps = buildList {
            if (restartFilter) add(Gap.FILTER_DOWN)
            if (restartLocation) add(Gap.LOCATION_DOWN)
            if (showLock) add(Gap.LOCK_NOT_SHOWN)
            if (!state.accessibilityEnabled) add(Gap.ACCESSIBILITY_OFF)
        }
        return Plan(restartFilter, restartLocation, showLock, gaps)
    }
}
