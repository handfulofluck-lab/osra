package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F2 follow-up: the fail-closed store is a real [NoopSharedPreferences], not just an empty map fake.
 * Every read must answer "absent" and every write must be dropped in memory — nothing may touch disk — and `commit()`
 * still reports success so a caller that checks the return does not fall back to another file.
 */
class NoopSharedPreferencesTest {

    private val store = NoopSharedPreferences()

    @Test
    fun `every read answers absent`() {
        assertNull(store.getString("device_token", null))
        assertEquals("absent returns the default, not null", "fallback", store.getString("device_token", "fallback"))
        assertFalse(store.contains("device_token"))
        assertFalse(store.contains("parent_pin_hash"))
        assertTrue(store.getAll().isEmpty())
    }

    @Test
    fun `writes are dropped and never read back`() {
        store.edit().putString("device_token", "jwt").putString("hmac_secret", "hmac")
        store.edit().putString("parent_pin_hash", "hash").apply()

        assertNull("a dropped write must not be readable", store.getString("device_token", null))
        assertNull(store.getString("hmac_secret", null))
        assertNull(store.getString("parent_pin_hash", null))
        assertTrue("nothing is stored", store.getAll().isEmpty())
    }

    @Test
    fun `remove and clear are no-ops`() {
        store.edit().putString("device_token", "jwt").remove("device_token").clear().commit()
        assertTrue(store.getAll().isEmpty())
    }

    @Test
    fun `edit returns the same editor and commit reports success without persisting`() {
        val editor = store.edit()
        assertSame("the store is its own editor", editor, store)
        assertTrue("commit reports success so callers do not fall back to another file", editor.putString("k", "v").commit())
        assertNull(store.getString("k", null))
    }

    @Test
    fun `non-string reads return their defaults and nothing throws`() {
        assertEquals(7, store.getInt("k", 7))
        assertEquals(9L, store.getLong("k", 9L))
        assertEquals(true, store.getBoolean("k", true))
        assertNull(store.getStringSet("k", null))
    }
}
