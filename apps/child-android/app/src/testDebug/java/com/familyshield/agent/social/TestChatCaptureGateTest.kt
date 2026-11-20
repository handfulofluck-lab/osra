package com.familyshield.agent.social

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [TestChatCaptureFilter] and source-level wiring guards for [TestChatCaptureGate].
 *
 * Mutants killed:
 * - M1: changing malformed-config branch from `false` to `true` (fail-open) breaks `malformed config fails closed`.
 * - M2: dropping salt or contact normalization breaks `matching contact passes across case and whitespace while other chats drop`.
 * - M3: removing `TestChatCaptureGate.allows(` before `queue.enqueue(` in `NotificationCaptureService` or `SocialCapture`
 *   breaks `both capture paths gate before queue enqueue`.
 * - M4: adding filter logic to `src/release/.../TestChatCaptureGate.kt` breaks `release stub carries no filter sentinel`.
 */
class TestChatCaptureGateTest {

    @Test
    fun `absent config leaves debug capture unrestricted`() {
        assertTrue(TestChatCaptureFilter.allows(null, "Any Chat"))
        assertTrue(TestChatCaptureFilter.allows(null, null))
    }

    @Test
    fun `matching contact passes across case and whitespace while other chats drop`() {
        val salt = "qa-local-salt"
        val digest = TestChatCaptureFilter.computeSaltedSha256Hex(salt, "Test Chat Alpha")
        val cfg = "salt=$salt\nsha256=$digest\n"

        assertTrue(TestChatCaptureFilter.allows(cfg, "Test Chat Alpha"))
        assertTrue(TestChatCaptureFilter.allows(cfg, "  test chat alpha  "))
        assertFalse(TestChatCaptureFilter.allows(cfg, "Other Family Chat"))
        assertFalse(TestChatCaptureFilter.allows(cfg, ""))
        assertFalse(TestChatCaptureFilter.allows(cfg, "   "))
        assertFalse(TestChatCaptureFilter.allows(cfg, null))
    }

    @Test
    fun `wrong salt or single-bit digest change is rejected`() {
        val salt = "qa-local-salt"
        val digest = TestChatCaptureFilter.computeSaltedSha256Hex(salt, "Test Chat Alpha")
        val flipped = (if (digest[0] == 'a') 'b' else 'a') + digest.substring(1)

        assertFalse(TestChatCaptureFilter.allows("salt=other-salt\nsha256=$digest\n", "Test Chat Alpha"))
        assertFalse(TestChatCaptureFilter.allows("salt=$salt\nsha256=$flipped\n", "Test Chat Alpha"))
    }

    @Test
    fun `malformed or incomplete config file fails closed`() {
        val digest = TestChatCaptureFilter.computeSaltedSha256Hex("s", "Test Chat Alpha")
        assertFalse(TestChatCaptureFilter.allows("", "Test Chat Alpha"))
        assertFalse(TestChatCaptureFilter.allows("   \n# comment only\n", "Test Chat Alpha"))
        assertFalse(TestChatCaptureFilter.allows("salt=s\n", "Test Chat Alpha"))
        assertFalse(TestChatCaptureFilter.allows("sha256=$digest\n", "Test Chat Alpha"))
        assertFalse(TestChatCaptureFilter.allows("salt=s\nsha256=not-64-hex\n", "Test Chat Alpha"))
        assertFalse(TestChatCaptureFilter.allows("salt=s\nsha256=$digest\nextra=1\n", "Test Chat Alpha"))
    }

    @Test
    fun `config comments and uppercase hex are accepted`() {
        val salt = "qa-local-salt"
        val digest = TestChatCaptureFilter.computeSaltedSha256Hex(salt, "Synthetic QA")
        val cfg = "# local device filter\nsalt = $salt\nsha256 = ${digest.uppercase()}\n"
        assertEquals(64, digest.length)
        assertTrue(TestChatCaptureFilter.allows(cfg, "synthetic qa"))
    }

    @Test
    fun `both capture paths gate before queue enqueue`() {
        val appDir = findAppDir()
        val notifSrc = File(appDir, "src/full/java/com/familyshield/agent/services/NotificationCaptureService.kt").readText()
        val socialSrc = File(appDir, "src/main/java/com/familyshield/agent/social/SocialCapture.kt").readText()

        val notifGateIdx = notifSrc.indexOf("TestChatCaptureGate.allows(")
        val notifEnqueueIdx = notifSrc.indexOf("queue.enqueue(")
        assertTrue("NotificationCaptureService must call TestChatCaptureGate.allows", notifGateIdx >= 0)
        assertTrue("NotificationCaptureService must gate before queue.enqueue", notifGateIdx < notifEnqueueIdx)

        val socialGateIdx = socialSrc.indexOf("TestChatCaptureGate.allows(")
        val socialEnqueueIdx = socialSrc.indexOf("queue.enqueue(")
        assertTrue("SocialCapture must call TestChatCaptureGate.allows", socialGateIdx >= 0)
        assertTrue("SocialCapture must gate before queue.enqueue", socialGateIdx < socialEnqueueIdx)
    }

    @Test
    fun `release stub carries no filter sentinel`() {
        val appDir = findAppDir()
        val releaseSrc = File(appDir, "src/release/java/com/familyshield/agent/social/TestChatCaptureGate.kt").readText()
        assertFalse(releaseSrc.contains("osra_test_chat_filter"))
        assertTrue(releaseSrc.contains("): Boolean = true"))
    }

    private fun findAppDir(): File {
        val candidates = listOf(File("."), File("app"))
        return candidates.firstOrNull { File(it, "src/main/java/com/familyshield/agent/social/SocialCapture.kt").exists() }
            ?: error("Could not locate apps/child-android/app directory from ${File(".").absolutePath}")
    }
}
