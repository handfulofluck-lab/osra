package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F2 follow-up: the secure pairing writes must never let a broken store pass as persisted. A
 * fail-closed store drops a write without throwing, so "no exception" is not evidence — the writer reads the value
 * back and refuses to report success until it is actually there. The same rule protects the legacy migration: the
 * plaintext copy is only deleted after the secure copy reads back.
 */
class SecureStoreWriterTest {

    private class FakeStore {
        var unreadable = false
        val values = mutableMapOf<String, String>()

        val writer = SecureStoreWriter(
            unreadable = { unreadable },
            putString = { key, value -> if (!unreadable && value != null) values[key] = value },
            getString = { key -> values[key] },
        )
    }

    @Test
    fun `a healthy store persists the token and secret, and the write reads back`() {
        val store = FakeStore()
        assertTrue(store.writer.writePairing("device_token", "jwt", "hmac_secret", "hmac"))
        assertEquals("jwt", store.values["device_token"])
        assertEquals("hmac", store.values["hmac_secret"])
    }

    @Test
    fun `an unreadable store writes nothing and reports failure, so the caller never caches a pairing`() {
        val store = FakeStore().apply { unreadable = true }
        assertFalse(store.writer.writePairing("device_token", "jwt", "hmac_secret", "hmac"))
        assertTrue("no secret is written", store.values.isEmpty())
    }

    @Test
    fun `a dropped write reports failure even though the store claimed not to be unreadable`() {
        // The write itself lands nowhere (the putString is a no-op) although the store looks writable.
        val store = FakeStore()
        val dropping = SecureStoreWriter(
            unreadable = { false },
            putString = { _, _ -> Unit },
            getString = { store.values[it] },
        )
        // getString reads a store that never receives the putString value.
        assertFalse(dropping.writePairing("device_token", "jwt", "hmac_secret", "hmac"))
    }

    @Test
    fun `a partial write that drops only the HMAC still reports failure`() {
        val store = FakeStore()
        val partial = SecureStoreWriter(
            unreadable = { false },
            putString = { key, value -> if (key == "device_token" && value != null) store.values[key] = value },
            getString = { store.values[it] },
        )
        // The token lands, the HMAC does not: pairing must still be refused, not half-persisted.
        assertFalse(partial.writePairing("device_token", "jwt", "hmac_secret", "hmac"))
    }

    @Test
    fun `a dropped token is refused when there is no HMAC to read back`() {
        val store = FakeStore()
        val droppingToken = SecureStoreWriter(
            unreadable = { false },
            putString = { _, _ -> Unit },
            getString = { store.values[it] },
        )
        assertFalse(droppingToken.writePairing("device_token", "jwt", "hmac_secret", null))
    }

    @Test
    fun `a dropped token is refused even when the HMAC persists`() {
        val store = FakeStore()
        val droppingToken = SecureStoreWriter(
            unreadable = { false },
            putString = { key, value -> if (key == "hmac_secret" && value != null) store.values[key] = value },
            getString = { store.values[it] },
        )
        assertFalse(droppingToken.writePairing("device_token", "jwt", "hmac_secret", "hmac"))
        assertEquals("hmac", store.values["hmac_secret"])
    }

    @Test
    fun `migrating into a healthy store returns the value, so the caller may delete the plaintext copy`() {
        val store = FakeStore()
        assertEquals("legacy-token", store.writer.migrate("device_token", "legacy-token"))
        assertEquals("legacy-token", store.values["device_token"])
    }

    @Test
    fun `migrating into an unreadable store fails closed, so the caller keeps the only plaintext copy`() {
        val store = FakeStore().apply { unreadable = true }
        assertNull(store.writer.migrate("device_token", "legacy-token"))
        assertTrue("nothing is written", store.values.isEmpty())
    }

    @Test
    fun `a dropped migration write fails closed instead of deleting the only credential copy`() {
        val store = FakeStore()
        val dropping = SecureStoreWriter(
            unreadable = { false },
            putString = { _, _ -> Unit },
            getString = { store.values[it] },
        )
        assertNull(dropping.migrate("device_token", "legacy-token"))
    }
}
