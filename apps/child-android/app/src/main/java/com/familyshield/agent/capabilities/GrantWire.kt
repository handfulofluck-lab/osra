package com.familyshield.agent.capabilities

import com.familyshield.agent.setup.OnboardingPolicy

/**
 * The wire name of each onboarding grant — the server's `GRANT_KEYS` vocabulary.
 *
 * Written out rather than derived from the enum's name (`lowercase()`), because a rename in Kotlin would then
 * silently invent a key the server does not know and the report would fail its strict schema. The pair is
 * pinned by a JVM row that compares these values against [CapabilitiesPolicy.GRANT_WIRE], the way
 * `LocationGrantState` is pinned against the server's enum.
 */
object GrantWire {

    fun name(grant: OnboardingPolicy.Grant): String = when (grant) {
        OnboardingPolicy.Grant.ACCESSIBILITY -> "accessibility"
        OnboardingPolicy.Grant.USAGE_ACCESS -> "usage_access"
        OnboardingPolicy.Grant.OVERLAY -> "overlay"
        OnboardingPolicy.Grant.DEVICE_ADMIN -> "device_admin"
        OnboardingPolicy.Grant.WEB_FILTER -> "web_filter"
        OnboardingPolicy.Grant.LOCATION -> "location"
        OnboardingPolicy.Grant.PRIVATE_DNS -> "private_dns"
        OnboardingPolicy.Grant.BATTERY -> "battery"
        OnboardingPolicy.Grant.USB_DEBUGGING -> "usb-debugging"
        OnboardingPolicy.Grant.NOTIFICATION_LISTENER -> "notification_listener"
    }
}
