package com.familyshield.agent.security

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Issue #225, bug 1: one device-admin deactivation must page the parent once. `onDisabled` enqueues
 * an expedited worker and the 60-s drain can enqueue the same work again; both derive the key from
 * deviceId, type and the disable timestamp, so the second run is a no-op.
 */
class TamperAlertDedupeTest {

    private class Recorder {
        val posted = mutableSetOf<String>()
        var posts = 0

        fun dispatcher() = TamperAlertDispatcher(
            wasPosted = { it in posted },
            recordPosted = { posted += it },
        )
    }

    @Test
    fun `onDisabled alert and the worker retry post exactly one alert`() = runBlocking {
        val recorder = Recorder()
        val dispatcher = recorder.dispatcher()
        val disabledAtMs = 1_700_000_000_000L
        val key = TamperAlertDedupe.adminRemovalKey("dev-1", disabledAtMs)

        // Run 1: the expedited work enqueued by GuardianAdminReceiver.onDisabled.
        assertTrue(dispatcher.dispatch(key) { recorder.posts++ })
        // Run 2: the 60-s drain saw the pending flag / tier drop and enqueued the same work.
        assertFalse(dispatcher.dispatch(key) { recorder.posts++ })

        assertEquals(1, recorder.posts)
        assertEquals(setOf(key), recorder.posted)
    }

    @Test
    fun `a second deactivation has a new timestamp and posts again`() = runBlocking {
        val recorder = Recorder()
        val dispatcher = recorder.dispatcher()

        dispatcher.dispatch(TamperAlertDedupe.adminRemovalKey("dev-1", 1_000L)) { recorder.posts++ }
        dispatcher.dispatch(TamperAlertDedupe.adminRemovalKey("dev-1", 2_000L)) { recorder.posts++ }

        assertEquals(2, recorder.posts)
    }

    @Test
    fun `a failed post is not recorded, so the retry still posts`() = runBlocking {
        val recorder = Recorder()
        val dispatcher = recorder.dispatcher()
        val key = TamperAlertDedupe.adminRemovalKey("dev-1", 42L)

        try {
            dispatcher.dispatch(key) { throw IllegalStateException("offline") }
            fail("the dispatch must propagate a failed post")
        } catch (expected: IllegalStateException) {
            assertEquals("offline", expected.message)
        }
        assertEquals(emptySet<String>(), recorder.posted)

        assertTrue(dispatcher.dispatch(key) { recorder.posts++ })
        assertEquals(1, recorder.posts)
    }

    @Test
    fun `alerts without a dedupe key keep their previous best-effort behaviour`() = runBlocking {
        val recorder = Recorder()
        val dispatcher = recorder.dispatcher()

        assertTrue(dispatcher.dispatch(null) { recorder.posts++ })
        assertTrue(dispatcher.dispatch(null) { recorder.posts++ })

        assertEquals(2, recorder.posts)
        assertEquals(emptySet<String>(), recorder.posted)
    }
}
