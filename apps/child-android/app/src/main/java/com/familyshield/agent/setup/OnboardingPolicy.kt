package com.familyshield.agent.setup

import androidx.annotation.StringRes
import com.familyshield.agent.R
import com.familyshield.agent.network.dto.RuleSetDto
import java.util.Locale

/**
 * Plan item 1.6 — guided, verified onboarding. The pure half: which grants the agent needs, which of
 * them are *required* before pairing may be called complete, the one-line reason the parent sees,
 * and the OEM-specific hint. [PairingActivity] supplies the live state (`granted`) by asking the OS
 * on every resume, so a parent who came back from Settings without granting sees the row still red.
 *
 * Acceptance for 1.6: *pairing cannot complete with a required permission missing.* "Required" is
 * what the product does not work without — the accessibility service (every block and the tamper
 * guard), usage access (limits), display over other apps (the lock), device admin (uninstall
 * protection), the web filter consent (1.4), location (locate / geofences) and Private DNS off a
 * named host (otherwise the web filter is bypassed). Battery exemption and the notification
 * listener (2.6) are recommended: without them the agent is slower, not absent. USB debugging off
 * (#81) is recommended too: a phone with it on can have OSRA's data cleared from any computer, but
 * families switch it on for real reasons, so it warns rather than blocks.
 *
 * #709: the title and the reason are **resource ids**, resolved by the screen, so an Arabic phone reads
 * Arabic. The OEM hint is not: it quotes the phone maker's own menu, and the Arabic Language Bureau holds
 * those lines until they can be read off an Arabic handset, so it stays English on purpose.
 */
object OnboardingPolicy {

    enum class Grant(
        @StringRes val titleRes: Int,
        @StringRes val whyRes: Int,
        val required: Boolean,
        @StringRes val c05TitleRes: Int,
        @StringRes val c05WhyRes: Int,
        @StringRes val c05ButtonRes: Int,
    ) {
        ACCESSIBILITY(
            R.string.onboarding_grant_accessibility_title,
            R.string.onboarding_grant_accessibility_why,
            true,
            R.string.c05_grant_accessibility_title,
            R.string.c05_grant_accessibility_why,
            R.string.c05_grant_accessibility_button,
        ),
        USAGE_ACCESS(
            R.string.onboarding_grant_usage_title,
            R.string.onboarding_grant_usage_why,
            true,
            R.string.c05_grant_usage_title,
            R.string.c05_grant_usage_why,
            R.string.c05_grant_usage_button,
        ),
        OVERLAY(
            R.string.onboarding_grant_overlay_title,
            R.string.onboarding_grant_overlay_why,
            true,
            R.string.c05_grant_overlay_title,
            R.string.c05_grant_overlay_why,
            R.string.c05_grant_overlay_button,
        ),
        DEVICE_ADMIN(
            R.string.onboarding_grant_device_admin_title,
            R.string.onboarding_grant_device_admin_why,
            true,
            R.string.c05_grant_device_admin_title,
            R.string.c05_grant_device_admin_why,
            R.string.c05_grant_device_admin_button,
        ),
        WEB_FILTER(
            R.string.onboarding_grant_web_filter_title,
            R.string.onboarding_grant_web_filter_why,
            true,
            R.string.c05_grant_web_filter_title,
            R.string.c05_grant_web_filter_why,
            R.string.c05_grant_web_filter_button,
        ),
        LOCATION(
            R.string.onboarding_grant_location_title,
            R.string.onboarding_grant_location_why,
            true,
            R.string.c05_grant_location_title,
            R.string.c05_grant_location_why,
            R.string.c05_grant_location_button,
        ),
        PRIVATE_DNS(
            R.string.onboarding_grant_private_dns_title,
            R.string.onboarding_grant_private_dns_why,
            true,
            R.string.c05_grant_private_dns_title,
            R.string.c05_grant_private_dns_why,
            R.string.c05_grant_private_dns_button,
        ),
        BATTERY(
            R.string.onboarding_grant_battery_title,
            R.string.onboarding_grant_battery_why,
            false,
            R.string.c05_grant_battery_title,
            R.string.c05_grant_battery_why,
            R.string.c05_grant_battery_button,
        ),
        USB_DEBUGGING(
            R.string.onboarding_grant_usb_title,
            R.string.onboarding_grant_usb_why,
            false,
            R.string.c05_grant_usb_title,
            R.string.onboarding_grant_usb_why,
            R.string.c05_grant_usb_button,
        ),
        // osra-security#78: required on the Full build (rows() omits it on Play via BuildConfig.CAPTURE_NOTIFICATIONS).
        NOTIFICATION_LISTENER(
            R.string.onboarding_grant_notification_title,
            R.string.onboarding_grant_notification_why,
            true,
            R.string.c05_grant_notification_title,
            R.string.c05_grant_notification_why,
            R.string.c05_grant_notification_button,
        ),
    }

    data class Row(val grant: Grant, val granted: Boolean)

    /** The progress line's resource and its two numbers, so the screen can format it in its own language. */
    data class ProgressLine(@StringRes val textRes: Int, val done: Int, val total: Int)

    /**
     * The rows in the order the parent should grant them (cheapest and most important first).
     *
     * [notificationCaptureAvailable] is the build's capability, not the OS grant: the Play artefact has no
     * `NotificationListenerService`, so asking a Play parent for notification access would request a
     * permission the build cannot use — and a store reviewer sees the request (ADR-0016 §4). Full passes
     * `true`, Play `false`, from `BuildConfig.CAPTURE_NOTIFICATIONS`.
     */
    fun rows(notificationCaptureAvailable: Boolean = true, granted: (Grant) -> Boolean): List<Row> =
        Grant.values()
            .filter { it != Grant.NOTIFICATION_LISTENER || notificationCaptureAvailable }
            .map { Row(it, granted(it)) }

    /** Grants still missing among the required ones; empty means pairing may be called complete. */
    fun missingRequired(rows: List<Row>): List<Grant> = rows.filter { it.grant.required && !it.granted }.map { it.grant }

    fun canComplete(rows: List<Row>): Boolean = missingRequired(rows).isEmpty()

    /** House rule (#1208 Arabic Bureau): always format user-visible counts with Western ASCII digits. */
    fun formatWesternInt(value: Int): String = String.format(Locale.US, "%d", value)

    /** Short progress line for the header: "5 of 7 steps done" or "All done. Your phone is protected." */
    fun progressLine(rows: List<Row>): String {
        val counts = counts(rows)
        return if (counts.done == counts.total) {
            "All done. Your phone is protected."
        } else {
            "${formatWesternInt(counts.done)} of ${formatWesternInt(counts.total)} steps done"
        }
    }

    /** C-05 (#1208 B2): real cached family rules shown on the agreement screen, or null when empty. */
    data class AgreementRulesSummary(
        val dailyLimitMinutes: Int?,
        val bedtimeStart: String?,
        val bedtimeEnd: String?,
        val schoolStart: String?,
        val schoolEnd: String?,
        val blockedCategories: List<String>,
    ) {
        val isEmpty: Boolean
            get() = dailyLimitMinutes == null &&
                bedtimeStart == null &&
                schoolStart == null &&
                blockedCategories.isEmpty()
    }

    fun agreementRulesSummary(ruleSet: RuleSetDto?): AgreementRulesSummary? {
        if (ruleSet == null) return null
        val dailyLimit = ruleSet.screenTime.dailyLimitMinutes.takeIf { it > 0 }
        val bedtimeStart = ruleSet.screenTime.bedtimeStart.trim().takeIf { it.isNotEmpty() }
        val bedtimeEnd = ruleSet.screenTime.bedtimeEnd.trim().takeIf { it.isNotEmpty() }
        val hasBedtime = bedtimeStart != null && bedtimeEnd != null && bedtimeStart != bedtimeEnd
        val schoolStart = ruleSet.screenTime.schoolHours.start.trim().takeIf { it.isNotEmpty() }
        val schoolEnd = ruleSet.screenTime.schoolHours.end.trim().takeIf { it.isNotEmpty() }
        val hasSchool = ruleSet.screenTime.schoolHours.days.isNotEmpty() &&
            schoolStart != null && schoolEnd != null && schoolStart != schoolEnd
        val categories = ruleSet.webFilter.blockedCategories
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
        val summary = AgreementRulesSummary(
            dailyLimitMinutes = dailyLimit,
            bedtimeStart = if (hasBedtime) bedtimeStart else null,
            bedtimeEnd = if (hasBedtime) bedtimeEnd else null,
            schoolStart = if (hasSchool) schoolStart else null,
            schoolEnd = if (hasSchool) schoolEnd else null,
            blockedCategories = categories,
        )
        return summary.takeUnless { it.isEmpty }
    }

    @StringRes
    fun webCategoryLabelRes(slug: String): Int? = when (slug.trim().lowercase(Locale.US)) {
        "pornography", "adult", "adult_content" -> R.string.c05_cat_pornography
        "gambling" -> R.string.c05_cat_gambling
        "drugs" -> R.string.c05_cat_drugs
        "violence" -> R.string.c05_cat_violence
        "weapons" -> R.string.c05_cat_weapons
        "hate" -> R.string.c05_cat_hate
        "self_harm" -> R.string.c05_cat_self_harm
        "dating" -> R.string.c05_cat_dating
        "social_media_nsfw" -> R.string.c05_cat_social_media_nsfw
        "chat_random" -> R.string.c05_cat_chat_random
        "proxies_vpn" -> R.string.c05_cat_proxies_vpn
        "warez" -> R.string.c05_cat_warez
        "ai_chatbots" -> R.string.c05_cat_ai_chatbots
        "social_media" -> R.string.c05_cat_social_media
        "chat" -> R.string.c05_cat_chat
        else -> null
    }

    /** The same line as a resource, for a screen that must render it in the phone's language. */
    fun progressLineRes(rows: List<Row>): ProgressLine = counts(rows).let { counts ->
        ProgressLine(
            textRes = if (counts.done == counts.total) R.string.onboarding_progress_complete else R.string.onboarding_progress,
            done = counts.done,
            total = counts.total,
        )
    }

    /** Required grants done / required grants in total. The one place the screen's two numbers come from. */
    private data class Counts(val done: Int, val total: Int)

    private fun counts(rows: List<Row>): Counts {
        val required = rows.filter { it.grant.required }
        return Counts(done = required.count { it.granted }, total = required.size)
    }

    /**
     * OEM hint for the grant, keyed on the manufacturer string (`Build.MANUFACTURER`, any case).
     * Samsung and Xiaomi are the two families that silently undo background work; the text tells the
     * parent where the hidden switch is. Null when there is nothing OEM-specific to say.
     */
    fun oemHint(grant: Grant, manufacturer: String?): String? {
        val m = manufacturer?.trim()?.lowercase() ?: return null
        return when {
            m.contains("samsung") -> when (grant) {
                Grant.BATTERY -> "Samsung: Settings › Battery › Background usage limits › Never sleeping apps → add OSRA; and turn off \"Put unused apps to sleep\"."
                Grant.ACCESSIBILITY -> "Samsung: Settings › Accessibility › Installed apps › OSRA › On. If it switches itself off, add OSRA to Never sleeping apps."
                else -> null
            }
            m.contains("xiaomi") || m.contains("redmi") || m.contains("poco") -> when (grant) {
                Grant.BATTERY -> "Xiaomi: Settings › Apps › Manage apps › OSRA › Autostart On, and Battery saver → No restrictions."
                Grant.OVERLAY -> "Xiaomi: Settings › Apps › Manage apps › OSRA › Other permissions › Display pop-up windows while running in the background → Allow."
                Grant.ACCESSIBILITY -> "Xiaomi: MIUI may turn the service off after a reboot unless Autostart is on for OSRA."
                else -> null
            }
            m.contains("huawei") || m.contains("honor") -> when (grant) {
                Grant.BATTERY -> "Huawei: Settings › Battery › App launch › OSRA → Manage manually, all three on."
                else -> null
            }
            m.contains("oppo") || m.contains("realme") || m.contains("oneplus") -> when (grant) {
                Grant.BATTERY -> "ColorOS: Settings › Battery › More settings › OSRA → Allow background activity; Auto-launch on."
                else -> null
            }
            else -> null
        }
    }

    /**
     * Issue #81: `Settings.Global.ADB_ENABLED` (readable without a permission) is 1 while USB debugging is
     * on. `adb shell pm clear` then wipes the agent despite device admin. Unknown counts as off.
     */
    fun usbDebuggingOff(adbEnabled: Int?): Boolean = adbEnabled == null || adbEnabled == 0

    /** Private DNS: Android's `private_dns_mode` is "off", "opportunistic" (Automatic) or "hostname" (a provider). */
    fun privateDnsOk(mode: String?): Boolean = mode == null || mode.trim().lowercase() != "hostname"

    /**
     * ADR-0021 B3 (and #95's sibling rule): a build that cannot capture something must **say so**, next to
     * the grants, instead of leaving the parent to discover a silent gap. Returns null when this build has
     * every capture path, so the caller renders nothing.
     */
    fun captureNotice(notificationCaptureAvailable: Boolean, callSmsCaptureAvailable: Boolean): String? {
        val missing = missingCaptures(notificationCaptureAvailable, callSmsCaptureAvailable)
        if (!missing.notifications && !missing.callSms) return null
        val what = buildList {
            if (missing.notifications) add("notification")
            if (missing.callSms) add("call and SMS")
        }.joinToString(" and ")
        return "This build captures messages from the screen only. The sideloaded Full build adds $what capture."
    }

    /**
     * The same notice as a resource, one whole line per case. The sweep forbids joining "notification",
     * "call and SMS" and "and" in code: an Arabic sentence cannot be assembled from English pieces.
     */
    @StringRes
    fun captureNoticeRes(notificationCaptureAvailable: Boolean, callSmsCaptureAvailable: Boolean): Int? {
        val missing = missingCaptures(notificationCaptureAvailable, callSmsCaptureAvailable)
        return when {
            missing.notifications && missing.callSms -> R.string.onboarding_capture_both
            missing.notifications -> R.string.onboarding_capture_notifications
            missing.callSms -> R.string.onboarding_capture_call_sms
            else -> null
        }
    }

    private data class MissingCaptures(val notifications: Boolean, val callSms: Boolean)

    private fun missingCaptures(notificationCaptureAvailable: Boolean, callSmsCaptureAvailable: Boolean) =
        MissingCaptures(notifications = !notificationCaptureAvailable, callSms = !callSmsCaptureAvailable)
}
