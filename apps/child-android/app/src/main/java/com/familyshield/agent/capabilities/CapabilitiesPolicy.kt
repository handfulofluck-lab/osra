package com.familyshield.agent.capabilities

import com.familyshield.agent.commands.CommandOutcome
import com.familyshield.agent.network.ClientHeader
import com.familyshield.agent.security.EnforceabilityPolicy
import com.familyshield.agent.security.ProfilePolicy

/**
 * ADR-0034 decision 1: what this phone can actually do, as the report the server stores.
 *
 * **Computed here, never derived on the server** — the agent is the only thing that knows whether the lock
 * screen can show on *this* phone, and the server repeats the verdict (A1). Two consequences shape this file:
 *
 * - a feature is `ready` only when the path that makes it work is **running**, not merely granted: the lock
 *   needs the accessibility service to re-raise the screen, which `EnforceabilityPolicy` already decides;
 * - a build that cannot do a feature at all **omits the key** rather than reporting `not_supported`.
 *   `not_supported` is the server's word, from its static table, and a device that claimed it outside its own
 *   row would be shown as `unavailable` — so the Play artefact says nothing about notifications or the
 *   call/sms log instead of saying something false.
 *
 * Pure and Android-free: [CapabilityFacts] carries primitives, the reporter gathers them, and every rule here
 * is a JVM row.
 */
object CapabilitiesPolicy {

    /** The server's `GRANT_KEYS`, in its order, with the wire name of each. */
    val GRANT_WIRE = listOf(
        "accessibility",
        "usage_access",
        "overlay",
        "device_admin",
        "web_filter",
        "location",
        "private_dns",
        "battery",
        "usb_debugging",
        "notification_listener",
        // `full_screen_intent` is iOS/desktop vocabulary and Android has no row for it on this build.
    )

    /** The two features the Play artefact cannot do at all, so it reports neither. */
    val FULL_ONLY_FEATURES = listOf("notification_scan", "call_sms_log")

    const val GRANTED = "granted"
    const val MISSING = "missing"
    const val NOT_APPLICABLE = "not_applicable"

    const val READY = "ready"
    const val DEGRADED = "degraded"
    const val UNAVAILABLE = "unavailable"

    /**
     * Everything the report needs, as primitives — what the reporter sees on the phone.
     *
     * [applicableGrants] is the build's list, not the OS's: the Play artefact never asks for notification
     * access (ADR-0016 §4), so for it that key is `not_applicable` rather than `missing`.
     */
    data class CapabilityFacts(
        val versionName: String?,
        val versionCode: Int,
        /** `BuildConfig.CAPTURE_CALL_SMS` — the Full artefact. */
        val fullBuild: Boolean,
        val applicableGrants: Set<String>,
        val grantedGrants: Set<String>,
        val accessibilityRunning: Boolean,
        val canOverlay: Boolean,
        val adminLocked: Boolean,
        val webFilterSetUp: Boolean,
        val tunnelRunning: Boolean,
        val backgroundLocation: Boolean,
        val callSmsGranted: Boolean,
        /** osra-security#6 item 2, or null when the reader could not be asked. */
        val profiles: ProfilePolicy.Report?,
    )

    /**
     * The report, or null when this build cannot name itself — a report with no `client` block fails the
     * server's strict schema, and a wrong build number is worse than no report (see [ClientHeader.value]).
     *
     * The client block is built from the same normaliser the header uses, so `X-OSRA-Client` and
     * `capabilities.client` can never disagree about which build a phone is running.
     */
    fun report(
        versionName: String?,
        versionCode: Int,
        flavour: String,
        facts: CapabilityFacts,
    ): Map<String, Any?>? {
        if (ClientHeader.value(versionName, versionCode, flavour) == null) return null
        val out = LinkedHashMap<String, Any?>()
        out["client"] = linkedMapOf(
            "app" to ClientHeader.APP,
            "version" to ClientHeader.version(versionName),
            "build" to versionCode,
            "flavour" to flavour,
        )
        out["grants"] = grants(facts)
        out["features"] = features(facts)
        facts.profiles?.let { out["profiles"] = mapOf("others" to it.others, "kinds" to it.kinds) }
        return out
    }

    /** One state per grant key, in the vocabulary's order. */
    fun grants(facts: CapabilityFacts): Map<String, String> = LinkedHashMap<String, String>().apply {
        for (key in GRANT_WIRE) {
            put(
                key,
                when {
                    key !in facts.applicableGrants -> NOT_APPLICABLE
                    key in facts.grantedGrants -> GRANTED
                    else -> MISSING
                },
            )
        }
    }

    /** One state per feature this build can do, in the vocabulary's order. */
    fun features(facts: CapabilityFacts): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        out["lock_screen"] = if (facts.canOverlay) READY else UNAVAILABLE
        out["pause_screen"] = applied(EnforceabilityPolicy.pauseOutcome(facts.canOverlay, facts.accessibilityRunning))
        // Blocking a launch is the accessibility service's job and nothing else's.
        out["app_blocking"] = if (facts.accessibilityRunning) READY else UNAVAILABLE
        out["screen_time"] = if (GRANTED == grantedState(facts, "usage_access")) READY else UNAVAILABLE
        // The filter is set up when its consent exists; it is only working when the tunnel is up, which is the
        // difference between ready and degraded rather than between ready and unavailable.
        out["web_filter"] = when {
            grantedState(facts, "web_filter") != GRANTED -> UNAVAILABLE
            facts.webFilterSetUp && facts.tunnelRunning -> READY
            else -> DEGRADED
        }
        out["pause_internet"] = applied(
            EnforceabilityPolicy.pauseInternetOutcome(facts.webFilterSetUp, facts.tunnelRunning),
        )
        // Foreground-only location is a weaker path the agent still serves, so it is degraded rather than
        // unavailable: a `locate_now` works while the app is in the foreground.
        out["location"] = when {
            grantedState(facts, "location") != GRANTED -> UNAVAILABLE
            facts.backgroundLocation -> READY
            else -> DEGRADED
        }
        // Removing the agent needs the admin to hold the uninstall screen, and the service to re-open it.
        out["uninstall_guard"] =
            if (grantedState(facts, "device_admin") == GRANTED && facts.accessibilityRunning) READY else UNAVAILABLE
        if (facts.fullBuild) {
            out["notification_scan"] =
                if (grantedState(facts, "notification_listener") == GRANTED) READY else UNAVAILABLE
            out["call_sms_log"] = if (facts.callSmsGranted) READY else UNAVAILABLE
        }
        return out
    }

    private fun grantedState(facts: CapabilityFacts, key: String): String =
        if (key in facts.grantedGrants && key in facts.applicableGrants) GRANTED else MISSING

    private fun applied(outcome: CommandOutcome): String =
        if (outcome is CommandOutcome.Applied) READY else UNAVAILABLE
}
