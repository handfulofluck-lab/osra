package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F2: how the secure store opens, driven through [SecureStoreOpener] with fakes, so each row checks
 * what happens, not what the source says. An unreadable encrypted store is reset (the phone re-pairs) and never
 * replaced by plaintext; only a Keystore that cannot open any encrypted store uses plaintext, and says so.
 *
 * Mutants (Claude's b3 and others): the reset branch returns plaintext → [two failures then a fresh store …]; one try
 * instead of two → [a single failure is retried …]; delete the fallback before copying, or overwrite existing values →
 * [opening the first time copies …].
 */
class SecureStoreOpeningTest {

    /** A store is a map; the label says which file it stands for. */
    private class Store(val label: String, val values: MutableMap<String, String> = mutableMapOf())

    private class Harness(failuresBeforeOpen: Int, val plain: Store = Store("plain")) {
        var failuresLeft = failuresBeforeOpen
        var encryptedOpens = 0
        var plainOpens = 0
        val deleted = mutableListOf<String>()
        /** Every effect in the order it happened: "copy", "delete:<file>". */
        val events = mutableListOf<String>()
        val encrypted = Store("encrypted", mutableMapOf("device_token" to "current"))

        val opener = SecureStoreOpener(
            openEncrypted = {
                encryptedOpens++
                if (failuresLeft > 0) { failuresLeft--; throw IllegalStateException("keystore") }
                encrypted
            },
            openPlain = { plainOpens++; plain },
            deleteFile = { name ->
                // The fallback must be read before it is deleted: a delete wipes the fake's contents.
                if (name == FALLBACK) plain.values.clear()
                deleted += name
                events += "delete:$name"
            },
            entries = { it.values.toMap() },
            contains = { store, key -> store.values.containsKey(key) },
            putAll = { store, values -> store.values.putAll(values); events += "copy" },
        )

        fun open(): Store = opener.open(FILE, FALLBACK)
    }

    @Test
    fun `opening the first time copies old plaintext keys in, never over a value, then deletes the fallback`() {
        val h = Harness(0, Store("plain", mutableMapOf("parent_pin_hash" to "pbkdf2\$old", "device_token" to "stale")))
        val store = h.open()
        assertSame(h.encrypted, store)
        assertEquals("pbkdf2\$old", store.values["parent_pin_hash"])
        assertEquals("an existing value is kept", "current", store.values["device_token"])
        assertEquals(listOf(FALLBACK), h.deleted)
        assertEquals("the copy happens before the fallback is deleted", listOf("copy", "delete:$FALLBACK"), h.events)
        assertFalse(h.opener.degraded)
    }

    @Test
    fun `a single failure is retried before anything is deleted or goes to plaintext`() {
        val h = Harness(1)
        val store = h.open()
        assertSame(h.encrypted, store)
        assertEquals(2, h.encryptedOpens)
        assertFalse("the encrypted file is not deleted", h.deleted.contains(FILE))
        assertFalse(h.opener.degraded)
    }

    @Test
    fun `two failures then a fresh store reset the file and never touch plaintext`() {
        val h = Harness(2, Store("plain", mutableMapOf("device_token" to "leaked")))
        val store = h.open()
        assertSame(h.encrypted, store)
        assertEquals(listOf(FILE, FALLBACK), h.deleted)
        assertEquals("openPlain is never called on the reset path", 0, h.plainOpens)
        assertFalse(h.opener.degraded)
        assertFalse("nothing old is copied into the fresh store", store.values.containsKey("parent_pin_hash"))
    }

    @Test
    fun `a Keystore that never opens falls back to plaintext and records it`() {
        val h = Harness(Int.MAX_VALUE)
        val store = h.open()
        assertSame(h.plain, store)
        assertTrue(h.opener.degraded)
        assertEquals(3, h.encryptedOpens)
        assertTrue(h.deleted.contains(FILE))
    }

    private companion object {
        const val FILE = "osra_secure_store"
        const val FALLBACK = "osra_secure_store_fallback"
    }
}
