package com.familyshield.agent

import com.familyshield.agent.commands.CommandAckPolicy
import com.familyshield.agent.commands.CommandAckSender
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
    fun `an unknown command or deferred locate_now is not acked here`() {
        assertNull(CommandAckPolicy.ackFor("c1", CommandOutcome.Ignored))
        assertNull(CommandAckPolicy.ackFor("c1", CommandOutcome.Deferred))
    }

    @Test
    fun `locate_now acks ok only when a fix exists and names its source`() {
        val fresh = CommandAckPolicy.locateAck("c1", LocateFix.FRESH)!!
        assertEquals("ok", fresh.status)
        assertEquals(mapOf("fix" to "fresh"), fresh.detail)

        val cached = CommandAckPolicy.locateAck("c1", LocateFix.CACHED)!!
        assertEquals("ok", cached.status)
        assertEquals(mapOf("fix" to "cached"), cached.detail)

        val none = CommandAckPolicy.locateAck("c1", null)!!
        assertEquals("failed", none.status)
        assertEquals(mapOf("reason" to CommandAckPolicy.REASON_LOCATION_UNAVAILABLE), none.detail)
        assertNull("the FCM path has no durable row to ack", CommandAckPolicy.locateAck(null, LocateFix.FRESH))
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
