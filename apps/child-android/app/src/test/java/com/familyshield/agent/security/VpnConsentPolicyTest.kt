package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnConsentPolicyTest {
    private fun classify(
        vararg text: String,
        windowClass: String? = "com.android.vpndialogs.ConfirmDialog",
        packageName: String = TamperScreenPolicy.VPN_DIALOG_PACKAGE,
        active: Boolean = true,
        ownRequest: Boolean = false,
    ): TamperScreen = TamperScreenPolicy.classify(
        packageName = packageName,
        texts = text.toList(),
        windowClass = windowClass,
        agentLabel = "OSRA Kids",
        adminLabel = "Parent controls",
        agentPackage = "com.example.agent",
        ourAdminActive = true,
        filterProtectionActive = active,
        ownVpnConsentPending = ownRequest,
    )

    @Test fun systemConsentWindowIsChecked() {
        assertTrue(TamperScreenPolicy.mayHostProtectionScreen(TamperScreenPolicy.VPN_DIALOG_PACKAGE))
        assertEquals(TamperScreen.VPN_CONSENT, classify("Connection request", "Example VPN"))
    }

    @Test fun systemDialogTitlesWorkWhenTheWindowClassIsUnavailable() {
        // Android platform VpnDialogs/res/values{,-ar}/strings.xml, key prompt.
        assertEquals(TamperScreen.VPN_CONSENT, classify("Connection request", windowClass = null))
        assertEquals(TamperScreen.VPN_CONSENT, classify("طلب الاتصال", windowClass = null))
    }

    @Test fun matchingLabelAloneDoesNotAuthorizeAConsentWindow() {
        assertEquals(TamperScreen.VPN_CONSENT, classify("Connection request", "OSRA Kids"))
        assertEquals(
            TamperScreen.VPN_CONSENT,
            classify("Connection request", "Example VPN", ownRequest = true),
        )
        assertEquals(TamperScreen.NONE, classify("Connection request", "OSRA Kids", ownRequest = true))
    }

    @Test fun aDifferentAppLabelIsGuardedWhileAuthorizedSetupIsPending() {
        val windowText = "Example VPN wants to set up a VPN connection"
        assertEquals(TamperScreen.VPN_CONSENT, classify(windowText, ownRequest = true))
    }

    @Test fun managementOnlyGuardsDisconnectingTheFilter() {
        assertEquals(TamperScreen.VPN_CONSENT, classify("OSRA Kids", "Disconnect", windowClass = "ManageDialog"))
        assertEquals(TamperScreen.NONE, classify("Example VPN", "Disconnect", windowClass = "ManageDialog"))
        assertEquals(TamperScreen.NONE, classify("OSRA Kids", "Configure", windowClass = "ManageDialog"))
    }

    @Test fun initialSetupAndANonSystemWindowDoNotTriggerTheGuard() {
        assertEquals(TamperScreen.NONE, classify("Connection request", active = false))
        assertEquals(
            TamperScreen.NONE,
            classify("Connection request", "Example VPN", packageName = "com.android.settings"),
        )
    }
}
