package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#6 item 2: the `profiles` part of the capability report, one row per mapping Claude set
 * on #6 from the Flip4 capture (user 95 = `android.os.usertype.profile.CLONE`, SDK 36).
 *
 * Mutants: map CLONE to `other` → [Dual Messenger is a clone]; read the type below 35 → [below API 35
 * every profile is other]; send empty kinds for an unknown type → [an unknown type is other, never
 * empty]; build kinds as a list instead of from the vocabulary → [two clones are others 2, one kind] and
 * [mixed kinds come in the server's order]; drop the cap → [never more than 8].
 */
class ProfilePolicyTest {

    @Test
    fun `no other profile is others 0 with no kinds`() {
        assertEquals(ProfilePolicy.Report(0, emptyList()), ProfilePolicy.report(emptyList(), 36))
    }

    @Test
    fun `Dual Messenger is a clone`() {
        assertEquals(ProfilePolicy.Report(1, listOf("clone")), ProfilePolicy.report(listOf(ProfilePolicy.TYPE_CLONE), 36))
    }

    @Test
    fun `a managed profile is work`() {
        assertEquals(ProfilePolicy.Report(1, listOf("work")), ProfilePolicy.report(listOf(ProfilePolicy.TYPE_MANAGED), 35))
    }

    @Test
    fun `an unknown or unreadable type is other, never empty`() {
        assertEquals(ProfilePolicy.Report(1, listOf("other")), ProfilePolicy.report(listOf("com.samsung.knox.whatever"), 36))
        assertEquals(ProfilePolicy.Report(1, listOf("other")), ProfilePolicy.report(listOf(null), 36))
    }

    @Test
    fun `below API 35 every profile is other, even a clone`() {
        assertEquals(ProfilePolicy.Report(1, listOf("other")), ProfilePolicy.report(listOf(ProfilePolicy.TYPE_CLONE), 34))
    }

    @Test
    fun `two clones are others 2, one kind`() {
        val clone = ProfilePolicy.TYPE_CLONE
        assertEquals(ProfilePolicy.Report(2, listOf("clone")), ProfilePolicy.report(listOf(clone, clone), 36))
    }

    @Test
    fun `mixed kinds come in the server's order`() {
        val r = ProfilePolicy.report(listOf(null, ProfilePolicy.TYPE_CLONE, ProfilePolicy.TYPE_MANAGED), 36)
        assertEquals(ProfilePolicy.Report(3, listOf("work", "clone", "other")), r)
    }

    @Test
    fun `never more than 8 others, and never more kinds than others`() {
        val r = ProfilePolicy.report(List(12) { null }, 36)
        assertEquals(8, r.others)
        assertEquals(listOf("other"), r.kinds)
        for (types in listOf(listOf(null, ProfilePolicy.TYPE_CLONE), List(9) { ProfilePolicy.TYPE_MANAGED })) {
            val out = ProfilePolicy.report(types, 36)
            assertTrue(out.kinds.size <= out.others)
            assertEquals(out.kinds.distinct(), out.kinds)
            assertTrue(out.kinds.isNotEmpty())
        }
    }

    @Test
    fun `the vocabulary matches the server's`() {
        assertEquals("shared-types PROFILE_KINDS", listOf("work", "clone", "secure_folder", "other"), ProfilePolicy.KINDS)
        assertEquals("shared-types PROFILES_MAX_OTHERS", 8, ProfilePolicy.MAX_OTHERS)
    }
}
