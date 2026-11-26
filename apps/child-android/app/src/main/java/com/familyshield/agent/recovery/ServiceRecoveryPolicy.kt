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
        /**
         * `LocationStartPolicy.shouldStart(...)` — fine or coarse granted **and**, from API 29, the
         * background grant held. Hydrogen's #1098 review: the old field was "fine or coarse", which let a
         * background worker start `LocationService` with only a while-in-use grant and crash the process,
         * the #128/#132 class of failure again.
         */
        val locationMayStart: Boolean,
        /** `LocationService.isServiceRunning`. */
        val locationRunning: Boolean,
        /** True when `LockState` says a lock is in force. */
        val lockActive: Boolean,
        /** Our accessibility service is switched on in Settings: the global switch and our component. */
        val accessibilityEnabled: Boolean,
        /**
         * The service is actually **bound** in this process (`AccessibilityMonitorService.isRunning`).
         * Hydrogen's #1098 review: the agent already exposes this, and after a kill it is `false` in the
         * fresh process while Settings still lists us — the exact state #1085 requirement 2 is about.
         */
        val accessibilityBound: Boolean,
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

        /**
         * The service is switched on in Settings but not bound in this process: the post-kill shape, where
         * Android marked it crashed and never rebound it. Only the user can turn it back on, so this is a
         * report, not an action.
         */
        ACCESSIBILITY_UNBOUND,
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
        val restartLocation = state.locationMayStart && !state.locationRunning
        val showLock = state.lockActive
        val gaps = buildList {
            if (restartFilter) add(Gap.FILTER_DOWN)
            if (restartLocation) add(Gap.LOCATION_DOWN)
            if (showLock) add(Gap.LOCK_NOT_SHOWN)
            if (!state.accessibilityEnabled) add(Gap.ACCESSIBILITY_OFF)
            // Enabled in Settings but not running here: MIUI's kill leaves exactly this state, and it is the
            // one #1085 was written for. Reported, never "restarted" — only the user can re-bind it.
            if (state.accessibilityEnabled && !state.accessibilityBound) add(Gap.ACCESSIBILITY_UNBOUND)
        }
        return Plan(restartFilter, restartLocation, showLock, gaps)
    }
}
