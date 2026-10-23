package com.familyshield.agent.commands

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The wiring the pure policy cannot prove: `show_reset_code` is routed to the new handler, the
 * handler defers its ack, the end of a notice is acked through the dispatcher, the code is forced
 * left-to-right, and the notification never carries it.
 *
 * Following `CommandDispatcherAckTest`'s source/file guards: these prove a reference, not semantics —
 * [ResetCodePolicyTest] proves the semantics and the phone row is out of scope. The Compose screen's
 * behaviour (the withdrawal close, the plural the device selects, the RTL paragraph) needs a device or
 * Robolectric, neither of which this suite has; each such claim is pinned below to the source shape
 * the fix depends on and named in the change's report.
 */
class ResetCodeWiringTest {

    private val dispatcher = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt").readText()
    private val activity = sourceFile("app/src/main/java/com/familyshield/agent/commands/ResetCodeActivity.kt").readText()

    /** Just the `showResetCode` handler, so a deferral elsewhere (locate_now) cannot satisfy the check. */
    private val handlerBody = dispatcher
        .substringAfter("private fun showResetCode")
        .substringBefore("/** ADR-0031: \"a code for your parent is waiting\"")

    /** The notification builder, so a payload field cannot be smuggled into it from elsewhere. */
    private val notificationBody = dispatcher
        .substringAfter("private fun postResetCodeNotification")
        .substringBefore("private fun cancelResetCodeNotification")

    /** The `Text` that renders the code, up to the next element in the column. */
    private val codeTextBlock = activity
        .substringAfter("text = ResetCodePolicy.formatCode(current.code)")
        .substringBefore("Spacer(")

    @Test
    fun `show_reset_code is routed, and its outcome is deferred until the notice ends`() {
        assertTrue(dispatcher.contains("\"show_reset_code\" -> showResetCode(data, commandId)"))
        assertTrue(
            "a display-time ack would clear the payload and stop the withdrawal redelivery",
            handlerBody.contains("CommandOutcome.Deferred"),
        )
    }

    @Test
    fun `the handler shows the notice through any path that can, and refuses only when none can`() {
        // Finding 4: notifications need no background-launch exemption, so they count as a way to
        // show the code. Refusing on `canLaunch` alone told the parent the phone could not show a
        // code a notification would have shown.
        assertTrue(
            "the overlay app-op or the bound accessibility service is the BAL exemption",
            handlerBody.contains("val canLaunch = Settings.canDrawOverlays(context) || AccessibilityMonitorService.isRunning"),
        )
        assertTrue(
            "notifications are the lock-screen path",
            handlerBody.contains("val canNotify = NotificationManagerCompat.from(context).areNotificationsEnabled()"),
        )
        assertTrue(
            "the refusal must consider both paths",
            handlerBody.contains("canShowScreen = canLaunch || canNotify"),
        )
        assertTrue("a notification is posted when it can be", handlerBody.contains("if (canNotify) postResetCodeNotification(decision.notice)"))
        assertTrue("and the screen only when a launch is allowed", handlerBody.contains("if (canLaunch) {"))
    }

    @Test
    fun `the notification never carries the code`() {
        // Finding 4: the notification is what a locked phone shows, so it may sit on the lock screen
        // — and must therefore say nothing a passer-by could use.
        assertFalse(
            "postResetCodeNotification must not read the code from the notice",
            notificationBody.contains(".code"),
        )
        assertTrue(notificationBody.contains("R.string.reset_code_title"))
        assertTrue(notificationBody.contains("R.string.reset_code_notification_text"))
        assertTrue(
            "the notification must expire with the code",
            notificationBody.contains("setTimeoutAfter(ResetCodePolicy.remaining(notice.expiresAt, Instant.now()).toMillis())"),
        )
        assertTrue(
            "the same channel as the other parent commands, not a duplicate",
            notificationBody.contains("CHANNEL_COMMANDS"),
        )
    }

    @Test
    fun `the notice and its notification are withdrawn together`() {
        assertTrue(
            "a withdrawn code must not leave a notification pointing at nothing",
            handlerBody.contains("ResetCodeState.clearIfCommand(decision.commandId)?.let { cancelResetCodeNotification() }"),
        )
        assertTrue("the Activity clears it too, at expiry", activity.contains("cancelResetCodeNotification()"))
        assertTrue(
            "one notification id, reachable from both classes",
            activity.contains("CommandDispatcher.RESET_CODE_NOTIFICATION_ID"),
        )
    }

    @Test
    fun `a withdrawal closes the notice, and the expired copy is kept for real expiry`() {
        // Finding 1: the usual reason for a withdrawal is the parent just using the code, so "ask
        // your parent to start again" tells the child the opposite of what happened.
        assertTrue(
            "the screen must ask whether this was its own expiry",
            activity.contains("ResetCodePolicy.viewOf(notice, expiredHere) == ResetCodeView.CLOSED"),
        )
        assertTrue("the screen must set its own expiry flag", activity.contains("expiredHere = true"))
        assertTrue("otherwise a vanished notice closes the screen", activity.contains("onWithdrawn: () -> Unit"))
        assertTrue("onCreate wires it to finish", activity.contains("onWithdrawn = ::finish"))
    }

    @Test
    fun `the code is forced left-to-right so an Arabic paragraph cannot reorder it`() {
        // Finding 2: `1234 5678` has no strong character, so in an RTL paragraph it renders 5678 1234
        // and the parent types a wrong code. The direction must not depend on the layout.
        assertTrue(
            "the code Text must set TextDirection.Ltr",
            codeTextBlock.contains("style = LocalTextStyle.current.copy(textDirection = TextDirection.Ltr)"),
        )
        assertTrue(codeTextBlock.contains("TextDirection.Ltr"))
    }

    @Test
    fun `a blank parent name falls back to the unnamed intro`() {
        // Finding 6: the name is copy, not the credential, so it cannot refuse the notice.
        assertTrue(activity.contains("if (current.parentName.isEmpty())"))
        assertTrue(activity.contains("stringResource(R.string.reset_code_intro_unnamed)"))
        assertTrue(activity.contains("stringResource(R.string.reset_code_intro, current.parentName)"))
    }

    @Test
    fun `the validity line is a plural resource`() {
        // Finding 3: "10 دقيقة" is wrong Arabic; the plural resource is what the device resolves.
        assertTrue(
            activity.contains("pluralStringResource(R.plurals.reset_code_valid_for, minutes, minutes)"),
        )
    }

    @Test
    fun `the code never travels in an intent extra`() {
        assertFalse(
            "the plaintext must live only in ResetCodeState; an extra is readable on the intent",
            activity.contains("putExtra"),
        )
        assertFalse(
            "the dispatcher must not attach the payload to the activity intent",
            dispatcher.contains("ResetCodeActivity::class.java).putExtra"),
        )
    }

    @Test
    fun `the ending is acked through the dispatcher, not by a second ack path here`() {
        assertTrue(activity.contains("dispatcher.ackResetCode(commandId, end)"))
        assertFalse(
            "the Activity must not build its own ack request",
            activity.contains("CommandAckDto"),
        )
        assertFalse(
            "nor call the API directly",
            activity.contains("api.ackCommand"),
        )
        assertTrue(dispatcher.contains("fun ackResetCode(commandId: String?, end: ResetCodeEnd)"))
        val ackBody = dispatcher.substringAfter("fun ackResetCode").substringBefore("\n    /**")
        assertTrue(
            "the dispatcher ack reuses reportOutcome, like ackLocateNow",
            ackBody.contains("reportOutcome(commandId, CommandOutcome.Applied(ResetCodePolicy.ackDetail(end)))"),
        )
        assertTrue("the expiry path must ack before clearing", activity.contains("ResetCodeEnd.EXPIRED"))
        assertTrue("a manual close must ack dismissed", activity.contains("ResetCodeEnd.DISMISSED"))
    }

    @Test
    fun `a superseded notice is acked with a screen value, not a boolean`() {
        assertTrue(handlerBody.contains("ResetCodeEnd.SUPERSEDED"))
        assertTrue(
            "detail.screen = superseded, like every other ending",
            handlerBody.contains("CommandOutcome.Applied(ResetCodePolicy.ackDetail(ResetCodeEnd.SUPERSEDED))"),
        )
        assertFalse(
            "the old `superseded = true` key is gone",
            handlerBody.contains("mapOf(\"superseded\" to \"true\")"),
        )
    }

    @Test
    fun `the activity is single-task, excluded from recents, and does not cover the keyguard`() {
        val manifest = manifest()
        val node = manifest.getElementsByTagName("activity")
            .let { nodes -> (0 until nodes.length).map { nodes.item(it) as Element } }
            .firstOrNull { it.getAttribute("android:name") == ".commands.ResetCodeActivity" }

        assertNotNull("ResetCodeActivity must be registered", node)
        val element = node!!
        assertEquals("false", element.getAttribute("android:exported"))
        assertEquals("singleTask", element.getAttribute("android:launchMode"))
        assertEquals("true", element.getAttribute("android:excludeFromRecents"))
        assertEquals("true", element.getAttribute("android:turnScreenOn"))
        assertNull(
            "issue #87: never draw over the keyguard; the notice starts behind it",
            element.getAttribute("android:showWhenLocked").takeIf { it.isNotEmpty() },
        )
    }

    private fun manifest(): org.w3c.dom.Document =
        DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(sourceFile("app/src/main/AndroidManifest.xml"))

    private fun sourceFile(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
