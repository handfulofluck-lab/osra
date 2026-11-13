package com.familyshield.agent

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import com.familyshield.agent.security.AdminEnrolmentMessages
import com.familyshield.agent.security.EnrolmentOutcome
import com.familyshield.agent.setup.LocationStatus
import com.familyshield.agent.setup.LocationStatusPolicy
import com.familyshield.agent.setup.OnboardingPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * #709: the English that used to be typed into the Android child's screens is now in `values/strings.xml`,
 * and the Arabic Language Bureau's approved wording (its 13 Nov 2026 sweep, #614) is in `values-ar`.
 *
 * Three things this holds:
 *
 * 1. **Every key is classified.** Each string in `values/strings.xml` either has a non-empty Arabic value
 *    or is named in [englishOnly]. A new key with neither is red, so a line cannot arrive English-only
 *    without someone saying so.
 * 2. **The screens read the resources, not their own copy of a sentence.** The same fault #506 caught on
 *    the block screen — Arabic in the resource, English still typed in the composable — is what this row
 *    looks for, file by file.
 * 3. **Where the pure policy keeps its English** (because its own unit rows pin it), the resource says the
 *    same sentence. Two copies that cannot drift, instead of two copies that can.
 *
 * Mutants: delete one Arabic value → [every key the sweep covers has Arabic]; put an English literal back
 * in `SosActivity` → [the screens take their words from resources]; reword `onboarding_progress` →
 * [the pure policies and their resources say the same English]. Placeholders are checked separately:
 * a dropped `%1$d` turns [the format arguments survive the translation] red.
 *
 * As in `ChildSystemStringsTest`, the resource merger is not on the JVM test classpath, so this reads the
 * two source files. How the screens render on a phone needs a device.
 */
class ChildScreenStringsTest {

    private val english = res("values/strings.xml")
    private val arabic = res("values-ar/strings.xml")

    /**
     * The lines the sweep does not give Arabic for. `app_name`, `app_name_ar` and `sos_tile_label` are
     * brand names, and `ChildSystemStringsTest` holds the rule that they keep no Arabic override — the
     * sweep offers «الاستغاثة» for the tile, so that one is the tile owner's call, not this test's.
     * The rest arrived with #709: the sweep's Android list has no line for them.
     */
    private val englishOnly = setOf(
        "app_name",
        "app_name_ar",
        "sos_tile_label",
        // SosActivity's round button carries the bare word; the sweep has no line for it.
        "sos_button",
        // The lock and pause overlays: the sweep's Android section does not cover LockActivity at all.
        "lock_locked_title",
        "lock_locked_body",
        "lock_paused_title",
        "lock_paused_body",
        "lock_paused_internet_title",
        "lock_paused_internet_body",
        // The foreground service's channel name in Settings; the sweep covers the other three channels.
        "notification_channel_location",
    )

    @Test
    fun `every key the sweep covers has Arabic, and nothing else does`() {
        // The real row: `values-ar` holds exactly the keys this file does not list as English-only. A new key
        // added without Arabic is neither translated nor listed, so it lands in the difference and this is red.
        assertEquals(
            "every string is either translated or named as English-only",
            english.keys - englishOnly,
            arabic.keys,
        )
        covered.forEach { key ->
            val value = arabic.value(key)
            assertTrue("'$key' has no Arabic value", value != null && value.isNotBlank())
        }
        englishOnly.forEach { key ->
            assertNull("'$key' is listed as English-only but has an Arabic value", arabic.value(key))
        }
    }

    @Test
    fun `the format arguments survive the translation`() {
        covered.forEach { key ->
            assertEquals("'$key' changed its format arguments", placeholders(english.value(key)), placeholders(arabic.value(key)))
        }
    }

    @Test
    fun `the plurals carry the same arguments, and Arabic has every form it needs`() {
        (english.plurals.keys + arabic.plurals.keys).forEach { name ->
            val en = english.plurals.getValue(name)
            val ar = arabic.plurals.getValue(name)
            assertTrue("'$name' has no `other` in English", en.containsKey("other"))
            assertTrue("'$name' has no `other` in Arabic", ar.containsKey("other"))
            assertTrue("'$name' lost a quantity Arabic needs", ar.keys.containsAll(en.keys))
            assertEquals("'$name' changed its format arguments", placeholders(en.getValue("other")), placeholders(ar.getValue("other")))
        }
    }

    @Test
    fun `the screens take their words from resources`() {
        screens.forEach { (path, screen) ->
            val source = codeOnly(locate(path).readText())
            screen.literals.forEach { literal ->
                assertFalse("$path still types out: $literal", source.contains("\"$literal\""))
            }
            screen.references.forEach { reference ->
                assertTrue("$path never reads $reference", source.contains(reference))
            }
            assertFalse("$path prints a resource name instead of resolving it", source.contains("\"R.string."))
        }
    }

    @Test
    fun `the pure policies and their resources say the same English`() {
        // The policy objects keep their English because their own rows pin it (`OnboardingPolicyTest` says
        // what `progressLine` returns, `LocationStatusPolicyTest` what the line and the button say,
        // `AdminEnrolmentPolicyTest` what the stale-Knox message says). The screens read the resource, so the
        // two must not drift: this row is the pin between them.
        val granted = OnboardingPolicy.rows(notificationCaptureAvailable = true) { true }
        assertEquals(string("onboarding_progress_complete", 7, 7), OnboardingPolicy.progressLine(granted))
        val noOverlay = OnboardingPolicy.rows(notificationCaptureAvailable = true) { it != OnboardingPolicy.Grant.OVERLAY }
        assertEquals(string("onboarding_progress", 6, 7), OnboardingPolicy.progressLine(noOverlay))

        assertEquals(string("onboarding_capture_notifications"), OnboardingPolicy.captureNotice(false, true))
        assertEquals(string("onboarding_capture_call_sms"), OnboardingPolicy.captureNotice(true, false))
        assertEquals(string("onboarding_capture_both"), OnboardingPolicy.captureNotice(false, false))

        LocationStatus.values().forEach { status ->
            assertEquals("the location line for $status", "\n" + string(locationLineKey(status)), LocationStatusPolicy.line(status))
        }
        assertEquals(string("location_action_grant"), LocationStatusPolicy.actionLabel(LocationStatus.MISSING_PERMISSION))
        assertEquals(string("location_action_allow_all_time"), LocationStatusPolicy.actionLabel(LocationStatus.MISSING_BACKGROUND))
        assertEquals(string("location_action_start"), LocationStatusPolicy.actionLabel(LocationStatus.SERVICE_STOPPED))

        val stale = AdminEnrolmentMessages.forOutcome(EnrolmentOutcome.STALE_KNOX_ADMIN)!!
        assertEquals(string("admin_stale_title"), stale.title)
        assertEquals(string("admin_stale_body"), stale.body)
        assertEquals(string("admin_stale_action"), stale.action)
        assertEquals(string("admin_parent_removal_note"), AdminEnrolmentMessages.PARENT_REMOVAL_NOTE)
    }

    @Test
    fun `every grant row has a title and a reason, and both are resources`() {
        // The enum carries ids now, so a row without one cannot compile; this is the check that no title or
        // reason is *empty*, which an id alone would not catch.
        OnboardingPolicy.Grant.values().forEach { grant ->
            val title = english.value(grantKey(grant, "title"))
            val why = english.value(grantKey(grant, "why"))
            assertTrue("$grant has no title", title != null && title.isNotBlank())
            assertTrue("$grant has no reason", why != null && why.isNotBlank())
            assertTrue("$grant has Arabic for its title", !arabic.value(grantKey(grant, "title")).isNullOrBlank())
            assertTrue("$grant has Arabic for its reason", !arabic.value(grantKey(grant, "why")).isNullOrBlank())
        }
    }

    // ---- the lists this test holds ----

    private fun grantKey(grant: OnboardingPolicy.Grant, part: String): String = when (grant) {
        OnboardingPolicy.Grant.ACCESSIBILITY -> "onboarding_grant_accessibility_$part"
        OnboardingPolicy.Grant.USAGE_ACCESS -> "onboarding_grant_usage_$part"
        OnboardingPolicy.Grant.OVERLAY -> "onboarding_grant_overlay_$part"
        OnboardingPolicy.Grant.DEVICE_ADMIN -> "onboarding_grant_device_admin_$part"
        OnboardingPolicy.Grant.WEB_FILTER -> "onboarding_grant_web_filter_$part"
        OnboardingPolicy.Grant.LOCATION -> "onboarding_grant_location_$part"
        OnboardingPolicy.Grant.PRIVATE_DNS -> "onboarding_grant_private_dns_$part"
        OnboardingPolicy.Grant.BATTERY -> "onboarding_grant_battery_$part"
        OnboardingPolicy.Grant.USB_DEBUGGING -> "onboarding_grant_usb_$part"
        OnboardingPolicy.Grant.NOTIFICATION_LISTENER -> "onboarding_grant_notification_$part"
    }

    private fun locationLineKey(status: LocationStatus): String = when (status) {
        LocationStatus.MISSING_PERMISSION -> "location_status_missing_permission"
        LocationStatus.MISSING_BACKGROUND -> "location_status_missing_background"
        LocationStatus.SERVICE_STOPPED -> "location_status_service_stopped"
        LocationStatus.ACTIVE -> "location_status_active"
    }

    private class Screen(val literals: List<String>, val references: List<String>)

    /**
     * What each screen must no longer say for itself, and what it must read instead. The literals are the
     * English the sweep found typed into the code; a re-worded one would slip past a literal check, so the
     * `R.string.` reference is asserted beside it.
     */
    private val screens = linkedMapOf(
        "src/main/java/com/familyshield/agent/sos/SosActivity.kt" to Screen(
            literals = listOf(
                "Need help right now?",
                "Stay calm — tap Cancel if this was accidental.",
                "Alert sent — stay where you are",
                "Your parent has been notified.",
                "SOS cancelled.",
            ),
            references = listOf(
                "R.string.sos_need_help",
                "R.string.sos_stay_calm",
                "R.string.sos_sent_title",
                "R.string.sos_sent_body",
                "R.string.sos_cancelled",
                "R.string.sos_cancel",
                "R.string.sos_close",
                "R.string.sos_sending",
            ),
        ),
        "src/main/java/com/familyshield/agent/commands/RingActivity.kt" to Screen(
            literals = listOf("Your parent is ringing this phone", "It keeps ringing until a parent stops it.", "Stop ringing (parent PIN)"),
            references = listOf("R.string.ring_title", "R.string.ring_body", "R.string.ring_stop"),
        ),
        "src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt" to Screen(
            literals = listOf(
                "Parent PIN",
                "Too many attempts. Ask your parent.",
                "Wrong PIN.",
                "Re-pairing this device needs your parent's PIN.",
            ),
            references = listOf(
                "R.string.pin_gate_title",
                "R.string.pin_gate_hint",
                "R.string.pin_gate_too_many",
                "R.string.pin_gate_wrong",
                "R.string.pin_gate_reason_repair",
                "R.string.pin_gate_reason_settings",
            ),
        ),
        "src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt" to Screen(
            literals = listOf("Camera preview", "Starting the camera…", "Cancel scanning", "Scan the pairing QR code", "Enter code instead"),
            references = listOf(
                "R.string.qr_preview_description",
                "R.string.qr_starting",
                "R.string.qr_cancel",
                "R.string.qr_rationale_title",
                "R.string.qr_enter_code",
                "R.string.qr_camera_ready",
            ),
        ),
        "src/main/java/com/familyshield/agent/commands/LockActivity.kt" to Screen(
            literals = listOf("Device paused by your parent", "Internet paused by your parent", "This device is locked by your parent"),
            references = listOf("R.string.lock_paused_title", "R.string.lock_paused_internet_title", "R.string.lock_locked_title"),
        ),
        "src/main/java/com/familyshield/agent/setup/PairingActivity.kt" to Screen(
            literals = listOf(
                "Protect this device",
                "Setup complete",
                "Open status",
                "This device is paired",
                "Re-pair (parent PIN)",
                "Remove protection (parent PIN)",
                "Server URL is required",
            ),
            references = listOf(
                "R.string.setup_protect_title",
                "R.string.setup_complete_title",
                "R.string.setup_open_status",
                "R.string.status_paired_title",
                "R.string.status_repair",
                "R.string.status_remove_protection",
                "R.string.setup_error_server_url_required",
                "OnboardingPolicy.progressLineRes",
                "LocationStatusPolicy.lineRes",
            ),
        ),
        "src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt" to Screen(
            literals = listOf("Parent commands", "Screen time ending", "Screen will lock in"),
            references = listOf(
                "R.string.notification_channel_commands",
                "R.string.notification_wind_down_title",
                "R.plurals.notification_wind_down_text",
            ),
        ),
        "src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt" to Screen(
            literals = listOf("Command checks", "Checking for parent commands"),
            references = listOf("R.string.notification_channel_command_checks", "R.string.notification_checking_commands"),
        ),
        "src/main/java/com/familyshield/agent/services/LocationService.kt" to Screen(
            literals = listOf("Location sharing is active"),
            references = listOf("R.string.notification_location_active", "R.string.notification_channel_location"),
        ),
        "src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt" to Screen(
            literals = listOf("Content filter", "Content filter active"),
            references = listOf("R.string.notification_channel_content_filter", "R.string.notification_content_filter_active"),
        ),
    )

    /** Every key in `values/strings.xml` that the sweep does cover: everything not in [englishOnly]. */
    private val covered: Set<String>
        get() = english.keys - englishOnly

    // ---- reading the two files ----

    private class Resources(val strings: Map<String, String>, val plurals: Map<String, Map<String, String>>) {
        val keys: Set<String> get() = strings.keys + plurals.keys

        fun value(key: String): String? = strings[key] ?: plurals[key]?.get("other")
    }

    private fun res(relativeToRes: String): Resources {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(locate("src/main/res/$relativeToRes"))
        val strings = document.getElementsByTagName("string")
        val plurals = document.getElementsByTagName("plurals")
        return Resources(
            strings = (0 until strings.length)
                .map { strings.item(it) as Element }
                .associate { it.getAttribute("name") to unescape(it.textContent) },
            plurals = (0 until plurals.length)
                .map { plurals.item(it) as Element }
                .associate { node ->
                    node.getAttribute("name") to
                        (0 until node.childNodes.length)
                            .map { node.childNodes.item(it) }
                            .filterIsInstance<Element>()
                            .associate { it.getAttribute("quantity") to unescape(it.textContent) }
                },
        )
    }

    /** The English line, formatted the way the screen formats it. */
    private fun string(key: String, vararg args: Any): String {
        val raw = english.value(key) ?: error("no English value for '$key'")
        return if (args.isEmpty()) raw else String.format(raw, *args)
    }

    /** Android's escapes, resolved the way aapt resolves them. */
    private fun unescape(raw: String): String = raw
        .replace("\\n", "\n")
        .replace("\\'", "'")
        .replace("\\\"", "\"")

    /** `%1$s`, `%2$d` … in the order they appear. */
    private fun placeholders(value: String?): List<String> =
        Regex("%[0-9]+\\$[sd]").findAll(value.orEmpty()).map { it.value }.toList()

    /** Strips block and line comments, so a source row judges code rather than prose. */
    private fun codeOnly(source: String): String =
        source.replace(Regex("/\\*[\\s\\S]*?\\*/"), "").replace(Regex("//[^\\n]*"), "")

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return listOf(File(working, relativeToModule), File(working, "app/$relativeToModule"))
            .firstOrNull { it.isFile }
            ?: error("could not find $relativeToModule below ${working.path}")
    }
}
