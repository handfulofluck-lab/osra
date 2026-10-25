package com.familyshield.agent.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.http.GET
import retrofit2.http.Query

/**
 * Issue #231 (Claude's D3 on #232): the server re-offers a `delivered`-but-unacked command after
 * 120 s **only to an agent that declares itself ack-capable**, and the agent never sent `?ack=1`.
 * So every "no ack, re-offered at 120 s" in #232 was in fact "no ack, stuck at `delivered` forever"
 * — the exact state #231 exists to remove.
 *
 * Retrofit annotations are readable at runtime, so this pins the contract structurally rather than
 * by grepping source. What is out of reach here: the *default value* of the parameter lives in the
 * Kotlin `$default` synthetic, not in the annotation. It is enforced by the compiler instead — the
 * two call sites ([com.familyshield.agent.commands.CommandPollWorker] and
 * [com.familyshield.agent.services.LocationService]) pass only the device id, so the module does not
 * compile unless a default exists. MockWebServer is not a dependency of this module, so the wire
 * request itself is covered by the phone row in the PR.
 */
class CommandPollAckCapabilityTest {

    /** Suspend functions compile with a trailing `Continuation`, so match by name, not arity. */
    private val method = ApiService::class.java.declaredMethods
        .firstOrNull { it.name == "getCommands" }
        ?: error("ApiService.getCommands is missing")

    private val ackParam = method.parameters.firstOrNull { it.isAnnotationPresent(Query::class.java) }

    @Test
    fun `the command poll declares the agent ack-capable`() {
        assertNotNull("the poll must carry a query parameter for ack-capability", ackParam)
        assertEquals(
            "the query parameter the server keys ack-capability on",
            "ack",
            ackParam!!.getAnnotation(Query::class.java).value,
        )
    }

    @Test
    fun `the ack parameter is an Int, so a call site cannot pass null or forget a value type`() {
        assertNotNull(ackParam)
        assertTrue(
            "an Int with a default is what makes every call site ack-capable",
            ackParam!!.type == Int::class.javaPrimitiveType,
        )
    }

    @Test
    fun `the poll path is unchanged, so a server that ignores the parameter still works`() {
        val get = method.getAnnotation(GET::class.java)
        assertNotNull("the poll must stay a GET", get)
        assertEquals("v1/devices/{id}/commands", get!!.value)
    }

    /**
     * Roadmap 5.8 (#353): the foreground service polls through `getCommandsWithCadence`, which keeps the
     * response headers for `X-Poll-After`. It is the same request, so it must declare the same
     * ack-capability. Mutant: drop its `@Query("ack")` and every poll from the service is a
     * non-ack-capable poll again, the #231 defect.
     */
    @Test
    fun `the header-reading poll is the same request, ack-capable too`() {
        val cadence = ApiService::class.java.declaredMethods
            .firstOrNull { it.name == "getCommandsWithCadence" }
            ?: error("ApiService.getCommandsWithCadence is missing")
        val ack = cadence.parameters.firstOrNull { it.isAnnotationPresent(Query::class.java) }
        assertNotNull("the cadence poll must carry the ack query parameter", ack)
        assertEquals("ack", ack!!.getAnnotation(Query::class.java).value)
        assertTrue(ack.type == Int::class.javaPrimitiveType)
        assertEquals("v1/devices/{id}/commands", cadence.getAnnotation(GET::class.java)?.value)
    }
}
