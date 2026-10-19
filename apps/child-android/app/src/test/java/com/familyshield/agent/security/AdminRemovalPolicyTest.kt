package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Test

/** Issue #186: removal must go through Knox when present and keep AOSP everywhere else. */
class AdminRemovalPolicyTest {

    private class FakeKnox(private val answer: () -> Boolean) : KnoxAdminApi {
        var calls = 0
        override fun deactivate(): Boolean {
            calls += 1
            return answer()
        }
    }

    @Test
    fun `Knox is chosen when the capability reports present`() {
        val knox = FakeKnox { true }
        var aospCalls = 0

        val route = AdminRemovalPolicy { knox }
            .remove(adminStillActive = { false }, aospRemove = { aospCalls += 1 })

        assertEquals(AdminRemovalRoute.KNOX, route)
        assertEquals(1, knox.calls)
        assertEquals(0, aospCalls)
    }

    @Test
    fun `AOSP is chosen when the capability reports absent`() {
        var aospCalls = 0

        val route = AdminRemovalPolicy { null }
            .remove(adminStillActive = { true }, aospRemove = { aospCalls += 1 })

        assertEquals(AdminRemovalRoute.AOSP, route)
        assertEquals(1, aospCalls)
    }

    @Test
    fun `AOSP is chosen when the probe throws, as any reflection failure must`() {
        var aospCalls = 0

        val route = AdminRemovalPolicy { throw IllegalStateException("NoSuchMethodException") }
            .remove(adminStillActive = { true }, aospRemove = { aospCalls += 1 })

        assertEquals(AdminRemovalRoute.AOSP, route)
        assertEquals(1, aospCalls)
        assertEquals(AdminRemovalRoute.AOSP, AdminRemovalPolicy { throw IllegalStateException() }.route())
    }

    @Test
    fun `AOSP is chosen when Knox throws during deactivation`() {
        var aospCalls = 0

        val route = AdminRemovalPolicy { FakeKnox { throw SecurityException("denied") } }
            .remove(adminStillActive = { true }, aospRemove = { aospCalls += 1 })

        assertEquals(AdminRemovalRoute.AOSP, route)
        assertEquals(1, aospCalls)
    }

    @Test
    fun `AOSP is chosen when Knox refuses the call`() {
        var aospCalls = 0

        val route = AdminRemovalPolicy { FakeKnox { false } }
            .remove(adminStillActive = { true }, aospRemove = { aospCalls += 1 })

        assertEquals(AdminRemovalRoute.AOSP, route)
        assertEquals(1, aospCalls)
    }

    @Test
    fun `AOSP still runs when Knox claims success but the admin remains active`() {
        var aospCalls = 0

        val route = AdminRemovalPolicy { FakeKnox { true } }
            .remove(adminStillActive = { true }, aospRemove = { aospCalls += 1 })

        assertEquals(AdminRemovalRoute.AOSP, route)
        assertEquals(1, aospCalls)
    }

    @Test
    fun `route reports the path removal will prefer`() {
        assertEquals(AdminRemovalRoute.KNOX, AdminRemovalPolicy { FakeKnox { true } }.route())
        assertEquals(AdminRemovalRoute.AOSP, AdminRemovalPolicy { null }.route())
    }
}
