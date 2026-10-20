package com.familyshield.agent

import com.familyshield.agent.commands.CommandAckPolicy
import com.familyshield.agent.commands.CommandAckSender
import com.familyshield.agent.commands.CommandDispatcher
import com.familyshield.agent.commands.CommandOutcome
import com.familyshield.agent.commands.LocateFix
import com.familyshield.agent.network.dto.CommandAckDto
import java.io.File
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #231: a command that succeeded never acked, so its durable row stayed `delivered` and the
 * parent's `/commands/history` said it had not been confirmed. `CommandDispatcher.dispatch()` needs
 * a `Context`, so the decision lives in [CommandAckPolicy] and is held here, following the
 * injected-lambda shape of `TamperAlertDispatcher`/`LocationGrantReporter`.
 *
 * Pinned here: `ok` means the effect is observable (for `locate_now`, once a fix exists — not when
 * the service is merely asked to start); a throwing handler is a `failed` ack and never also an
 * `ok`; no command id means no ack; a lost ack is logged once and not retried.
 */
class CommandDispatcherAckTest {

    /** The one ack a dispatch produces, if any — the same list `dispatch()` would send. */
    private fun acksFor(commandId: String?, handler: () -> CommandOutcome): List<CommandAckDto> =
        listOfNotNull(CommandAckPolicy.ackAfter(commandId, handler))

    @Test
    fun `a handler that returns normally produces exactly one ok ack`() {
        var runs = 0

        val acks = acksFor("c1") {
            runs += 1
            CommandOutcome.Applied()
        }

        assertEquals("the handler must run once", 1, runs)
        assertEquals("exactly one ack", 1, acks.size)
        assertEquals("ok", acks.single().status)
        assertNull(acks.single().detail)
    }

    @Test
    fun `a throwing handler produces one failed ack and no ok`() {
        val acks = acksFor("c1") { throw IllegalStateException("startActivity refused") }

        assertEquals(listOf("failed"), acks.map { it.status })
        assertEquals(mapOf("reason" to CommandAckPolicy.REASON_HANDLER_FAILED), acks.single().detail)
        assertTrue("a failed command must not also claim ok", acks.none { it.status == "ok" })
    }

    @Test
    fun `a refused command keeps the #132 reason in the failed ack`() {
        val ack = CommandAckPolicy.ackFor("c1", CommandOutcome.Refused("background_location_missing"))

        assertEquals("failed", ack!!.status)
        assertEquals(mapOf("reason" to "background_location_missing"), ack.detail)
    }

    @Test
    fun `a null or blank command id acks nothing, even for a thrown handler`() {
        assertNull(CommandAckPolicy.ackFor(null, CommandOutcome.Applied()))
        assertNull(CommandAckPolicy.ackFor("  ", CommandOutcome.Applied()))
        assertNull(CommandAckPolicy.ackFor(null, CommandOutcome.Refused("command_failed")))
        assertTrue(acksFor(null) { throw IllegalStateException("boom") }.isEmpty())
    }

    @Test
    fun `a deferred locate_now is acked by the service, not here`() {
        assertNull(CommandAckPolicy.ackFor("c1", CommandOutcome.Deferred))
    }

    @Test
    fun `an unknown command type is refused as unsupported instead of left delivered`() {
        val ack = CommandAckPolicy.ackFor("c1", CommandDispatcher.unknownTypeOutcome())!!

        assertEquals("failed", ack.status)
        assertEquals(mapOf("reason" to "unsupported_command"), ack.detail)
    }

    @Test
    fun `an unparseable minutes payload is refused as invalid instead of left delivered`() {
        val ack = CommandAckPolicy.ackFor("c1", CommandDispatcher.invalidMinutesOutcome())!!

        assertEquals("failed", ack.status)
        assertEquals(mapOf("reason" to "invalid_payload"), ack.detail)
    }

    @Test
    fun `locate_now acks ok only when a fix exists and names its source`() {
        val fresh = CommandAckPolicy.locateAck("c1", LocateFix.FRESH, uploaded = true)!!
        assertEquals("ok", fresh.status)
        assertEquals(mapOf("fix" to "fresh"), fresh.detail)

        val cached = CommandAckPolicy.locateAck("c1", LocateFix.CACHED, uploaded = true)!!
        assertEquals("ok", cached.status)
        assertEquals(mapOf("fix" to "cached"), cached.detail)

        val none = CommandAckPolicy.locateAck("c1", null, uploaded = false)!!
        assertEquals("failed", none.status)
        assertEquals(mapOf("reason" to CommandAckPolicy.REASON_LOCATION_UNAVAILABLE), none.detail)
        assertNull(
            "the FCM path has no durable row to ack",
            CommandAckPolicy.locateAck(null, LocateFix.FRESH, uploaded = true),
        )
    }

    @Test
    fun `a fix whose upload failed sends no ack, so the row is re-offered at 120 s`() {
        // Issue #231 review: flushPings() used to swallow the upload failure, so a `fresh` ack could
        // go out while the point was only buffered on the phone. No upload means no observable effect.
        assertNull(CommandAckPolicy.locateAck("c1", LocateFix.FRESH, uploaded = false))
        assertNull(CommandAckPolicy.locateAck("c1", LocateFix.CACHED, uploaded = false))
    }

    @Test
    fun `a successful ack is sent exactly once`() = runBlocking {
        val sent = mutableListOf<Pair<String, CommandAckDto>>()
        val sender = CommandAckSender(
            send = { id, ack -> sent += id to ack },
            log = { message, _ -> throw AssertionError("unexpected log: $message") },
        )

        sender.sendOnce("c1", CommandAckDto(status = "ok"))

        assertEquals(1, sent.size)
        assertEquals("c1", sent.single().first)
        assertEquals("ok", sent.single().second.status)
    }

    @Test
    fun `a lost ack is logged once, not retried in a loop, and does not fail the command`() = runBlocking {
        val sent = mutableListOf<String>()
        val logged = mutableListOf<String>()
        val sender = CommandAckSender(
            send = { id, _ ->
                sent += id
                throw IOException("offline")
            },
            log = { message, _ -> logged += message },
        )

        // Returning normally is the contract: the poll loop and the command outcome must not see it.
        sender.sendOnce("c1", CommandAckDto(status = "ok"))

        assertEquals("the ack is attempted once, never retried here", listOf("c1"), sent)
        assertEquals(1, logged.size)
        assertTrue(logged.single().contains("c1"))
    }

    /**
     * The decision is pure; `dispatch()` is the wiring. This guard fails if a later refactor stops
     * routing outcomes through the policy, or acks `locate_now` before the service knows a fix.
     * It proves a reference, not the semantics — the tests above prove the semantics.
     */
    @Test
    fun `CommandDispatcher routes outcomes through the ack policy and defers locate_now`() {
        val dispatcher = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        val service = sourceFile("app/src/main/java/com/familyshield/agent/services/LocationService.kt")

        assertTrue(dispatcher.contains("CommandAckPolicy.outcomeOf"))
        assertTrue(dispatcher.contains("CommandAckPolicy.ackFor"))
        assertTrue(dispatcher.contains("CommandAckPolicy.locateAck"))
        assertTrue(
            "starting the location service is not a fix: locate_now must defer its ok ack",
            dispatcher.contains("CommandOutcome.Deferred"),
        )
        assertTrue(service.contains("ackLocateNow"))
        assertTrue(
            "lock/pause must be acked by the enforceability policy, not unconditionally",
            dispatcher.contains("EnforceabilityPolicy.lockOutcome") &&
                dispatcher.contains("EnforceabilityPolicy.pauseOutcome"),
        )
        assertTrue(
            "unlock/resume must decide from the visible screen, so the unlock is only launched when " +
                "there is something to take down (issue #233 review F1/F2)",
            dispatcher.contains("EnforceabilityPolicy.unlockOutcome") &&
                dispatcher.contains("LockActivity.isShowing"),
        )
        assertTrue(
            "unlock/resume must share the policy-carrying handler, so resume cannot lose the reason",
            !dispatcher.contains("unlock(); CommandOutcome.Applied()"),
        )
        assertTrue(
            "the unlock ack must name the screen it found, not a via path",
            dispatcher.contains("lockScreenShowing = showing"),
        )
        assertTrue(
            "accessibility running is the bound service, not a cached setting",
            dispatcher.contains("AccessibilityMonitorService.isRunning"),
        )
        assertTrue(
            "the web filter must be prepared in the OS, not just the stored consent flag",
            dispatcher.contains("FilterVpnService.isPrepared(context)"),
        )
        assertTrue(
            "unknown types and malformed minutes must be refused, not left unaudited",
            dispatcher.contains("unknownTypeOutcome()") && dispatcher.contains("invalidMinutesOutcome()"),
        )
        assertTrue(
            "flushPings must report whether it uploaded",
            service.contains("suspend fun flushPings(): Boolean"),
        )
        assertTrue(
            "the locate ack must carry the flush result, so a buffered fix is not acked",
            service.contains("ackLocateNow(commandId, fix, uploaded)"),
        )
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
