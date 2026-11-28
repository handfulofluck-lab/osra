package com.familyshield.agent.setup

import android.os.Build
import android.provider.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1287 finding 2: the Accessibility step must choose OSRA's own switch where the platform supports it, and the
 * general list where the OEM skin does not. Mutants: always choose the details screen (a dead button on MIUI), or
 * never choose it (today's behaviour, the parent hunts through "Downloaded apps").
 */
class AccessibilitySettingsIntentTest {

    @Test
    fun `the component extra is a flattened string, which is what Settings reads`() {
        // Codex's review of #1301: AOSP's AccessibilityDetailsSettingsFragment unflattens a String; a
        // ComponentName parcelable extra is ignored and the screen falls back to the general list.
        assertEquals(
            "com.osratech.child.full/com.osratech.child.full.services.AccessibilityMonitorService",
            AccessibilitySettingsIntent.componentExtra(
                "com.osratech.child.full",
                "com.osratech.child.full.services.AccessibilityMonitorService",
            ),
        )
    }

    @Test
    fun `on API 33 and later with a resolvable details screen, it chooses our own switch`() {
        val choice = AccessibilitySettingsIntent.chooseAction(
            sdkInt = Build.VERSION_CODES.TIRAMISU,
            resolvesDetails = true,
        )
        assertEquals(AccessibilitySettingsIntent.ACTION_DETAILS, choice.action)
        assertTrue(choice.withComponent)
    }

    @Test
    fun `on API 33 and later without a details screen, it falls back to the general list`() {
        val choice = AccessibilitySettingsIntent.chooseAction(
            sdkInt = Build.VERSION_CODES.TIRAMISU,
            resolvesDetails = false,
        )
        assertEquals(Settings.ACTION_ACCESSIBILITY_SETTINGS, choice.action)
        assertFalse(choice.withComponent)
    }

    @Test
    fun `before API 33 it stays on the general list, resolvable or not`() {
        for (resolves in listOf(true, false)) {
            val choice = AccessibilitySettingsIntent.chooseAction(
                sdkInt = Build.VERSION_CODES.S_V2,
                resolvesDetails = resolves,
            )
            assertEquals("resolves=$resolves", Settings.ACTION_ACCESSIBILITY_SETTINGS, choice.action)
        }
    }
}
