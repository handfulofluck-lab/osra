package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F2: the secure store no longer falls back to plaintext on any failure. An unreadable encrypted store
 * (a restored backup, a corrupt file) is reset and the phone re-pairs; only a Keystore that cannot open any encrypted
 * store keeps the plaintext fallback, and says so.
 *
 * Mutants: fall back to plaintext on the first failure → [an unreadable store is reset, not replaced by plaintext];
 * drop the second try → [a single failure is retried before anything is deleted]; drop the move of old plaintext
 * secrets → [secrets an older build left in plaintext move into the encrypted store].
 */
class SecureStoreOpeningTest {

    private val source by lazy { sourceFile("app/src/main/java/com/familyshield/agent/security/SecureStore.kt") }

    @Test
    fun `the decision for each way the store can open`() {
        assertEquals(SecureStoreOpening.Outcome.ENCRYPTED, SecureStoreOpening.decide(firstOpened = true, retryOpened = false))
        assertEquals(SecureStoreOpening.Outcome.RESET_ENCRYPTED, SecureStoreOpening.decide(firstOpened = false, retryOpened = true))
        assertEquals(SecureStoreOpening.Outcome.PLAINTEXT_DEGRADED, SecureStoreOpening.decide(firstOpened = false, retryOpened = false))
    }

    @Test
    fun `an unreadable store is reset, not replaced by plaintext`() {
        val open = source.substringAfter("private fun open()").substringBefore("private fun encrypted()")
        assertTrue("the unreadable file is deleted before the retry", open.contains("context.deleteSharedPreferences(FILE)"))
        val beforeDecision = open.substringBefore("SecureStoreOpening.decide(")
        assertFalse("no plaintext store is opened before the decision", beforeDecision.contains("FALLBACK_FILE"))
        val degraded = open.substringAfter("Outcome.PLAINTEXT_DEGRADED ->")
        assertTrue("the plaintext store is only the last outcome, and recorded", degraded.contains("degraded = true"))
    }

    @Test
    fun `a single failure is retried before anything is deleted`() {
        val open = source.substringAfter("private fun open()").substringBefore("private fun encrypted()")
        val firstLine = open.lines().first { it.contains("val first =") }
        assertEquals("two attempts on the same file", 2, Regex("""runCatching \{ encrypted\(\) \}""").findAll(firstLine).count())
    }

    @Test
    fun `secrets an older build left in plaintext move into the encrypted store`() {
        val open = source.substringAfter("private fun open()").substringBefore("private fun encrypted()")
        assertTrue(open.contains("Outcome.ENCRYPTED -> first.getOrThrow().also(::adoptPlaintextFallback)"))
        val adopt = source.substringAfter("private fun adoptPlaintextFallback(").substringBefore("\n    }")
        assertTrue("copied in", adopt.contains("putString(k, v as String)"))
        assertTrue("then the plaintext file goes", adopt.contains("dropPlaintextFallback(target)"))
        assertTrue(source.contains("context.deleteSharedPreferences(FALLBACK_FILE)"))
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
