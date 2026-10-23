package com.familyshield.agent.services

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The must-fix from Claude's Decision 2 (#319, 2026-10-23): `FirebaseMessagingSvc` used to read
 * `msg.data["type"]` and hand the message to `CommandDispatcher`, so Google saw every command's content
 * (a reset code, a family's day). A push is a wake-up only: `PushWakeHandler` polls in-process once and
 * falls back to a one-shot `CommandPollWorker`.
 *
 * Three independent guards, because any one alone can be routed around:
 *  1. reflection — the service declares no `CommandDispatcher` field or constructor parameter. That is
 *     checked against the compiled class, so the compulsion to reintroduce one is a build error first
 *     and this failure second.
 *  2. source — the `onMessageReceived` body indexes `msg.data` nowhere and routes every message through
 *     `PushWakeHandler.onPushReceived`, with `CommandPoller.pollOnce` as the poll and
 *     `CommandPollWorker.requestFetchNow` as the fallback. Reflection cannot see a method body, and an
 *     `EntryPointAccessors` lookup would bypass a field-only guard.
 *  3. source — the `PushWakeHandler.onPushReceived` body itself never indexes its `data` parameter, so
 *     the "content is never read" guarantee is not only a test of the caller.
 *
 * All run in `testPlayDebugUnitTest` / `testFullDebugUnitTest` with no Firebase project: the service
 * class only has to load, which is why the seam itself is pure JVM
 * ([com.familyshield.agent.push.PushWakeHandlerTest]). Out of reach: that FCM delivers the message on a
 * device — the hardware row in the PR.
 */
class FirebaseMessagingSvcWiringTest {

    private val service = FirebaseMessagingSvc::class.java

    private val dispatcherType = "com.familyshield.agent.commands.CommandDispatcher"

    /**
     * Mutant: restore `@Inject lateinit var dispatcher: CommandDispatcher` and this fails with
     * `FirebaseMessagingSvc declares [dispatcher] of type CommandDispatcher` — the data-dispatch
     * dependency is back and `onMessageReceived` can reach `dispatch(type, data)` again.
     */
    @Test
    fun `the service holds no CommandDispatcher field, so a data dispatch cannot return`() {
        val fields = service.declaredFields
            .filter { it.type.name == dispatcherType }
            .map { it.name }

        assertTrue(
            "FirebaseMessagingSvc declares $fields of type CommandDispatcher. A push is a wake-up " +
                "only (#319, Decision 2): the service must not be able to dispatch command data. " +
                "Remove the field and go through PushWakeHandler (CommandPoller.pollOnce, with " +
                "CommandPollWorker.requestFetchNow as the fallback).",
            fields.isEmpty(),
        )
    }

    /** Mutant: a constructor parameter of type `CommandDispatcher` fails with the same message. */
    @Test
    fun `no constructor takes a CommandDispatcher`() {
        val params = service.declaredConstructors
            .flatMap { it.parameterTypes.toList() }
            .filter { it.name == dispatcherType }
            .map { it.name }

        assertTrue(
            "FirebaseMessagingSvc has a constructor parameter of type CommandDispatcher ($params). " +
                "A push is a wake-up only (#319, Decision 2): injected command dispatch is the defect " +
                "this test names, whether it arrives as a field or as a parameter.",
            params.isEmpty(),
        )
    }

    /**
     * Mutant: put `val type = msg.data["type"] ?: return` back into `onMessageReceived` and the
     * `msg.data[` assertion fails (`onMessageReceived reads message content`), even if the handler call
     * is left in place — the content read is the defect, not only the dispatch.
     */
    @Test
    fun `onMessageReceived reads no command content and wakes through the handler`() {
        val source = sourceFile("app/src/main/java/com/familyshield/agent/services/FirebaseMessagingSvc.kt")
            .readText()
        val body = source
            .substringAfter("override fun onMessageReceived(")
            .substringBefore("override fun onNewToken(")

        assertFalse(
            "onMessageReceived reads message content. A push is a wake-up only (#319, Decision 2): " +
                "Google must never see a command type, payload or id, and a stale token must leak " +
                "nothing. Drop the `msg.data[...]` read and wake through PushWakeHandler.",
            body.contains("msg.data["),
        )
        assertFalse(
            "onMessageReceived references CommandDispatcher. The fetch goes through " +
                "PushWakeHandler -> CommandPoller.pollOnce (#319, Decision 2), never a direct dispatch.",
            body.contains("CommandDispatcher") || body.contains("commandDispatcher"),
        )
        assertTrue(
            "onMessageReceived must route every message through PushWakeHandler.onPushReceived",
            body.contains("PushWakeHandler.onPushReceived("),
        )
        assertTrue(
            "the in-process attempt must be the poller's single fetch path",
            body.contains("poller.pollOnce()"),
        )
        assertTrue(
            "the worker must be the fallback trigger",
            body.contains("CommandPollWorker.requestFetchNow("),
        )
    }

    /**
     * The handler's own body must not index `data`: the guarantee is "no content is read", not "the
     * caller happens not to pass interesting content".
     *
     * Mutant: add `if (data["type"] == null) return` to `PushWakeHandler.onPushReceived` and this fails
     * with `PushWakeHandler reads message content` (and `PushWakeHandlerTest`'s content-equivalence case
     * fails too).
     */
    @Test
    fun `the wake handler never inspects the message data`() {
        val source = sourceFile("app/src/main/java/com/familyshield/agent/push/PushWakeHandler.kt")
            .readText()
        val body = source.substringAfter("suspend fun onPushReceived(")

        assertFalse(
            "PushWakeHandler reads message content. A push is a wake-up only (#319, Decision 2): " +
                "Google must never see a command type, payload or id. The data parameter must stay " +
                "unread.",
            body.contains("data[") || body.contains("data.get") || body.contains("data.containsKey"),
        )
        assertTrue("the in-process poll must be the primary attempt", body.contains("poll()"))
        assertTrue("a failed poll must enqueue the fallback", body.contains("fallback.requestFetch()"))
    }

    /** Walks up from the Gradle working directory (the `app` module) to the repository root. */
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
