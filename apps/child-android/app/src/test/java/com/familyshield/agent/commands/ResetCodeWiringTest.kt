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
 * handler defers its ack, and the Activity is registered in the reviewed shape.
 *
 * Following `CommandDispatcherAckTest`'s source/file guards: these prove a reference, not semantics —
 * [ResetCodePolicyTest] proves the semantics and the phone row is out of scope.
 */
class ResetCodeWiringTest {

    private val dispatcher = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt").readText()
    private val activity = sourceFile("app/src/main/java/com/familyshield/agent/commands/ResetCodeActivity.kt").readText()

    /** Just the `showResetCode` handler, so a deferral elsewhere (locate_now) cannot satisfy the check. */
    private val handlerBody = dispatcher
        .substringAfter("private fun showResetCode")
        .substringBefore("/** Sends at most one ack")

    @Test
    fun `show_reset_code is routed, and its outcome is deferred until the notice ends`() {
        assertTrue(dispatcher.contains("\"show_reset_code\" -> showResetCode(data, commandId)"))
        assertTrue(
            "a display-time ack would clear the payload and stop the withdrawal redelivery",
            handlerBody.contains("CommandOutcome.Deferred"),
        )
    }

    @Test
    fun `the handler proves a background-launch path before it starts the screen`() {
        assertTrue(
            "the overlay app-op or the bound accessibility service is the BAL exemption",
            handlerBody.contains("Settings.canDrawOverlays(context) || AccessibilityMonitorService.isRunning"),
        )
        assertTrue(handlerBody.contains("ResetCodePolicy.decide"))
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
    fun `the ending is reported in the ok ack`() {
        assertTrue(activity.contains("CommandAckDto(status = \"ok\""))
        assertTrue(activity.contains("ResetCodePolicy.ackDetail(end)"))
        assertTrue("the expiry path must ack before clearing", activity.contains("ResetCodeEnd.EXPIRED"))
        assertTrue("a manual close must ack dismissed", activity.contains("ResetCodeEnd.DISMISSED"))
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
