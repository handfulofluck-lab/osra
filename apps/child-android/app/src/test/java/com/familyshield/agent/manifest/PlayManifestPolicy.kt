package com.familyshield.agent.manifest

/**
 * ADR-0021's allow and deny lists for the Play artefact, as data a test can iterate.
 *
 * The finding this closes (F2, #101 review): `FlavorManifestTest` asserts **source** manifests, and CI's
 * `aapt2` step only dumps badging, so a library that declares `READ_SMS`, `READ_CALL_LOG`,
 * `QUERY_ALL_PACKAGES` or another Play-forbidden permission is merged into the Play build with every
 * gate still green. Two lists are therefore both necessary:
 *
 * - the **deny** list names the permissions and components Play policy forbids (ADR-0021 decisions 1, 2,
 *   5), with the reason, so the failure message explains itself;
 * - the **allow** list is the reviewed permission set of the Play artefact. It catches the permission
 *   nobody wrote a rule for yet — a dependency's new `FOREGROUND_SERVICE_*`, a telephony permission with
 *   a different spelling — which a deny list alone would let through.
 *
 * Adding a permission to the allow list is a policy decision: it needs the ADR-0021 review that says why
 * Play permits it. The Play build's `<queries>` are asserted too, because decision 5 keeps the two dialer
 * intents that S1 / #83 depend on, and a "tidy-up" that removes them weakens the emergency-dialer
 * exemption silently.
 */
object PlayManifestPolicy {

    /** Every permission the Play artefact may carry after merging, with where it comes from. */
    val ALLOWED_PERMISSIONS: Map<String, String> = linkedMapOf(
        "android.permission.INTERNET" to "src/main — API calls",
        "android.permission.ACCESS_FINE_LOCATION" to "src/main — locate (plan 1.7); Play location declaration at release",
        "android.permission.ACCESS_BACKGROUND_LOCATION" to "src/main — locate while backgrounded; its own Play declaration (ADR-0021, Not decided here)",
        "android.permission.FOREGROUND_SERVICE" to "src/main — LocationService / FilterVpnService (#128)",
        "android.permission.FOREGROUND_SERVICE_LOCATION" to "src/main — LocationService foregroundServiceType=location (#128)",
        "android.permission.FOREGROUND_SERVICE_SPECIAL_USE" to "src/main — FilterVpnService foregroundServiceType=specialUse (#128)",
        "android.permission.WAKE_LOCK" to "src/main — command polling",
        "android.permission.RECEIVE_BOOT_COMPLETED" to "src/main — BootReceiver",
        "android.permission.SCHEDULE_EXACT_ALARM" to "src/main — schedule windows",
        "android.permission.PACKAGE_USAGE_STATS" to "src/main — usage/app-limit statistics (user-granted; ADR-0021 keeps it)",
        "android.permission.SYSTEM_ALERT_WINDOW" to "src/main — block/tamper overlays (ADR-0010)",
        "android.permission.POST_NOTIFICATIONS" to "src/main — API 33+ foreground notification",
        "android.permission.ACCESS_NETWORK_STATE" to "firebase-messaging 24.0.0 — IID token creation",
        "com.google.android.c2dm.permission.RECEIVE" to "firebase-messaging 24.0.0 — FCM delivery",
        "com.familyshield.agent.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" to "androidx.core — context-registered receivers; declared signature permission of this app",
    )

    /** Permissions that must never appear in the Play artefact, with the decision that forbids each. */
    val FORBIDDEN_PERMISSIONS: Map<String, String> = linkedMapOf(
        "android.permission.READ_SMS" to "ADR-0021 decision 2 — Play's SMS policy has no parental-control exception",
        "android.permission.READ_CALL_LOG" to "ADR-0021 decision 2 — Play's Call-Log policy has no parental-control exception",
        "android.permission.QUERY_ALL_PACKAGES" to "ADR-0021 decision 5 — package visibility is the narrow <queries> block",
        "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE" to "ADR-0016 §4, ADR-0021 decision 1 — the listener is Full-only",
        "android.permission.READ_PHONE_STATE" to "not allowed by ADR-0021 (no listed exception) and not needed by ADR-0003 device auth",
        "android.permission.RECEIVE_SMS" to "same Play SMS policy as READ_SMS — Full-only",
        "android.permission.SEND_SMS" to "same Play SMS policy as READ_SMS — Full-only",
        "android.permission.WRITE_CALL_LOG" to "same Play Call-Log policy as READ_CALL_LOG — Full-only",
        "android.permission.PROCESS_OUTGOING_CALLS" to "same Play Call-Log policy as READ_CALL_LOG — Full-only",
    )

    /** Intent actions that may only be registered by the Full artefact. */
    val FORBIDDEN_INTENT_ACTIONS: Map<String, String> = linkedMapOf(
        "android.service.notification.NotificationListenerService" to "ADR-0016 §4 — notification capture is Full-only",
        "android.provider.Telephony.SMS_RECEIVED" to "ADR-0021 decision 2 — SMS capture is Full-only",
        "android.intent.action.PHONE_STATE" to "ADR-0021 decision 2 — call-log capture is Full-only",
        "android.intent.action.NEW_OUTGOING_CALL" to "ADR-0021 decision 2 — call-log capture is Full-only",
    )

    /** Class-name fragments that may only exist in the Full artefact. */
    val FORBIDDEN_COMPONENT_MARKERS: Map<String, String> = linkedMapOf(
        "NotificationCaptureService" to "ADR-0016 §4 — the notification listener is Full-only",
        ".comms.CommsLogger" to "ADR-0021 decision 2 — call/SMS harvest lives in src/full",
    )

    data class RequiredQuery(val action: String, val category: String?, val why: String)

    /** ADR-0021 decision 5: the three intents the Play `<queries>` block must keep. */
    val REQUIRED_QUERIES: List<RequiredQuery> = listOf(
        RequiredQuery("android.intent.action.MAIN", "android.intent.category.LAUNCHER", "the user-visible app list / app limits"),
        RequiredQuery("com.android.phone.EmergencyDialer.DIAL", null, "#83 emergency-dialer exemption — S1 depends on it"),
        RequiredQuery("android.intent.action.DIAL", null, "#83 emergency-dialer exemption — S1 depends on it"),
    )

    const val MONITORING_FLAG = "isMonitoringTool"
    const val MONITORING_VALUE = "child_monitoring"

    /** Forbidden, and not-on-the-allow-list, permissions. Empty means the set was reviewed. */
    fun permissionViolations(manifest: MergedManifest): List<String> {
        val violations = mutableListOf<String>()
        for (permission in manifest.includedPermissions.sorted()) {
            val denied = FORBIDDEN_PERMISSIONS[permission]
            when {
                denied != null -> violations += "FORBIDDEN $permission — $denied"
                permission !in ALLOWED_PERMISSIONS ->
                    violations += "UNREVIEWED $permission — not on PlayManifestPolicy.ALLOWED_PERMISSIONS; " +
                        "add it only with the ADR-0021 review that says why Play permits it"
            }
        }
        return violations
    }

    /** Components and intent filters that belong to the Full artefact only. */
    fun componentViolations(manifest: MergedManifest): List<String> {
        val violations = mutableListOf<String>()
        for (component in manifest.components) {
            for ((marker, reason) in FORBIDDEN_COMPONENT_MARKERS) {
                if (marker in component.name) {
                    violations += "FORBIDDEN component ${component.tag} ${component.name} — $reason"
                }
            }
            for (action in component.intentActions) {
                FORBIDDEN_INTENT_ACTIONS[action]?.let { reason ->
                    violations += "FORBIDDEN intent-filter action $action on ${component.tag} ${component.name} — $reason"
                }
            }
        }
        // A `<service>`/`<receiver>` node the merger deduplicated could still leave an action behind, so
        // check the whole set as well as the per-component walk above.
        for (action in manifest.componentIntentActions) {
            if (action in FORBIDDEN_INTENT_ACTIONS && violations.none { it.contains(action) }) {
                violations += "FORBIDDEN intent-filter action $action — ${FORBIDDEN_INTENT_ACTIONS[action]}"
            }
        }
        return violations
    }

    fun queryViolations(manifest: MergedManifest): List<String> = REQUIRED_QUERIES
        .filterNot { manifest.hasQuery(it.action, it.category) }
        .map { missing ->
            "MISSING <queries> intent ${missing.action}" +
                (missing.category?.let { " + $it" } ?: "") + " — ${missing.why}"
        }

    fun monitoringViolations(manifest: MergedManifest): List<String> {
        val declared = manifest.applicationMetaData[MONITORING_FLAG]
        if (declared == MONITORING_VALUE) return emptyList()
        return listOf(
            "MISSING monitoring declaration: <application> meta-data $MONITORING_FLAG " +
                "should be \"$MONITORING_VALUE\", found ${declared ?: "nothing"} — ADR-0021 decision 3",
        )
    }
}
