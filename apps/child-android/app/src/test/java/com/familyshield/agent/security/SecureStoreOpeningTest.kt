package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F2 (fail-closed after Ahmed's review, superseding the #563 plaintext fallback): how the secure
 * store opens, driven through [SecureStoreOpener] with fakes, so each row checks what happens, not what the source
 * says. A healthy store keeps the old behaviour: an older build's plaintext secrets migrate into the encrypted store
 * and the fallback file is deleted; one Keystore hiccup is retried; an unreadable encrypted file is deleted and
 * opened fresh (the phone re-pairs). When the encrypted store still will not open, the store **fails closed**:
 * the plaintext fallback is never opened or written, the legacy plaintext file is deleted, and the returned store is
 * empty — so [com.familyshield.agent.data.AgentSettings.isPaired] reads false (no device token) and the parent PIN is
 * gone. That empty-store signature is the [com.familyshield.agent.setup.WipeDetector] wipe, which flags the next
 * pairing claim with `dataCleared` and the server raises the tamper alert on the parent's Allow.
 *
 * Mutants (Claude's b3 and others): the fail-closed branch returns plaintext → [three failures fail closed …]; one try
 * instead of two → [a single failure is retried …]; delete the fallback before copying, or overwrite existing values →
 * [opening the first time copies …]; copy anything into the empty store, or leave the legacy fallback behind →
 * [a Keystore that never opens fails closed …].
 */
class SecureStoreOpeningTest {

    /** A store is a map; the label says which file it stands for. */
    private class Store(val label: String, val values: MutableMap<String, String> = mutableMapOf())

    private class Harness(failuresBeforeOpen: Int, val plain: Store = Store("plain")) {
        var failuresLeft = failuresBeforeOpen
        var encryptedOpens = 0
        var plainOpens = 0
        var emptyOpens = 0
        val deleted = mutableListOf<String>()
        /** Every effect in the order it happened: "copy", "delete:<file>". */
        val events = mutableListOf<String>()
        val encrypted = Store("encrypted", mutableMapOf("device_token" to "current"))
        /** What fail-closed returns: holds nothing and never receives a copy. */
        val empty = Store("empty")

        val opener = SecureStoreOpener(
            openEncrypted = {
                encryptedOpens++
                if (failuresLeft > 0) { failuresLeft--; throw IllegalStateException("keystore") }
                encrypted
            },
            openPlain = { plainOpens++; plain },
            empty = { emptyOpens++; empty },
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
        assertFalse(h.opener.unreadable)
    }

    @Test
    fun `a single failure is retried before anything is deleted or goes to plaintext`() {
        val h = Harness(1)
        val store = h.open()
        assertSame(h.encrypted, store)
        assertEquals(2, h.encryptedOpens)
        assertFalse("the encrypted file is not deleted", h.deleted.contains(FILE))
        assertFalse(h.opener.unreadable)
    }

    @Test
    fun `two failures then a fresh store reset the file and never touch plaintext`() {
        val h = Harness(2, Store("plain", mutableMapOf("device_token" to "leaked")))
        val store = h.open()
        assertSame(h.encrypted, store)
        assertEquals(listOf(FILE, FALLBACK), h.deleted)
        assertEquals("openPlain is never called on the reset path", 0, h.plainOpens)
        assertFalse(h.opener.unreadable)
        assertFalse("nothing old is copied into the fresh store", store.values.containsKey("parent_pin_hash"))
    }

    @Test
    fun `three failures fail closed - no plaintext fallback is opened or written, and the phone reads unpaired`() {
        val h = Harness(3, Store("plain", mutableMapOf("device_token" to "leaked")))
        val store = h.open()
        assertSame(h.empty, store)
        assertTrue(h.opener.unreadable)
        assertEquals("the plaintext fallback is never opened on the fail-closed path", 0, h.plainOpens)
        assertEquals("both files are cleaned up", listOf(FILE, FALLBACK), h.deleted)
        assertFalse("no secret is copied anywhere", h.events.contains("copy"))
        assertTrue("an empty store means AgentSettings.isPaired() is false", store.values.isEmpty())
    }

    @Test
    fun `a Keystore that never opens fails closed and never writes a secret`() {
        val h = Harness(Int.MAX_VALUE, Store("plain", mutableMapOf("parent_pin_hash" to "pbkdf2\$old")))
        val store = h.open()
        assertSame(h.empty, store)
        assertTrue(h.opener.unreadable)
        assertEquals(3, h.encryptedOpens)
        assertEquals("openPlain is never called", 0, h.plainOpens)
        assertTrue("the encrypted file is deleted", h.deleted.contains(FILE))
        assertTrue("the legacy plaintext fallback is deleted", h.deleted.contains(FALLBACK))
        assertFalse("no secret is copied anywhere", h.events.contains("copy"))
        assertTrue("the store holds no secret and no token", store.values.isEmpty())
    }

    @Test
    fun `the unreadable flag is per-open - a later healthy open clears it for the next pairing`() {
        val broken = Harness(Int.MAX_VALUE)
        broken.open()
        assertTrue("the broken open fails closed", broken.opener.unreadable)

        // A later process (or a recovered Keystore) opens the same kind of store fresh.
        val recovered = Harness(0, Store("plain"))
        val store = recovered.open()

        assertSame(recovered.encrypted, store)
        assertFalse("a later healthy open clears the unreadable state", recovered.opener.unreadable)
    }

    private companion object {
        const val FILE = "osra_secure_store"
        const val FALLBACK = "osra_secure_store_fallback"
    }
}
