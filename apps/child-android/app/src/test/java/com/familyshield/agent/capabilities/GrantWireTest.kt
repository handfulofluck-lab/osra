package com.familyshield.agent.capabilities

import com.familyshield.agent.setup.OnboardingPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * ADR-0034 decision 1: the grant names this agent sends are exactly the ones the server's vocabulary has.
 *
 * The server's schema is strict and keyed by enum, so a name the vocabulary does not know rejects the whole
 * report, and a grant the vocabulary has but this agent never sends shows as a hole in the parent's setup list.
 * This row is the pair: every onboarding grant maps to one wire name, and every wire name is a grant.
 */
class GrantWireTest {

    @Test
    fun `the ten onboarding grants are the vocabulary, one name each, with nothing invented`() {
        val names = OnboardingPolicy.Grant.entries.map { GrantWire.name(it) }
        assertEquals("no two grants share a wire name", names.size, names.toSet().size)
        assertEquals(
            "the agent's names and the server's vocabulary are the same set",
            CapabilitiesPolicy.GRANT_WIRE.toSet(),
            names.toSet(),
        )
    }

    @Test
    fun `the names are the server's spellings, not the enum's`() {
        // A rename in Kotlin must not silently become a key the server cannot parse, which is why the mapping
        // is written out rather than derived with `lowercase()`.
        assertEquals("usb_debugging", GrantWire.name(OnboardingPolicy.Grant.USB_DEBUGGING))
        assertEquals("notification_listener", GrantWire.name(OnboardingPolicy.Grant.NOTIFICATION_LISTENER))
        assertEquals("device_admin", GrantWire.name(OnboardingPolicy.Grant.DEVICE_ADMIN))
    }
}
