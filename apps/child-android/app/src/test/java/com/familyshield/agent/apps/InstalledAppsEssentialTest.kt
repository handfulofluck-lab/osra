package com.familyshield.agent.apps

import com.familyshield.agent.enforcement.PackageFacts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #199 item 5: the inventory the phone uploads carries `essential`, computed **on the device**
 * with `EssentialPackages.isEssential(packageId, PackageFacts)`.
 *
 * Why the phone and not the parent or the server: only the device knows the OS roles — which package
 * currently holds the dialer role, which answers HOME — and a name table is exactly what the #83 review
 * refused to trust (`com.anything.dialer` used to buy a lock bypass). The parent field is display only.
 *
 * Mutant: replace `EssentialPackages.isEssential(packageId, facts)` with `false` in `inventoryApp` and
 * the first row goes red.
 */
class InstalledAppsEssentialTest {

    private val dialer = "com.samsung.android.dialer"
    private val launcher = "com.sec.android.app.launcher"
    private val browser = "com.example.browser"

    /** The OS says these hold the roles; nothing in the table decides on its own here. */
    private val facts = object : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = pkg in setOf(dialer, launcher)
        override fun dialerRoleHolders(): Set<String> = setOf(dialer)
        override fun homePackages(): Set<String> = setOf(launcher)
    }

    @Test
    fun `the dialer leaves the phone as essential`() {
        val dto = inventoryApp(dialer, "Phone", isSystem = true, facts = facts)
        assertTrue("a rule on the dialer would silently do nothing", dto.essential)
        assertEquals(dialer, dto.packageId)
        assertEquals("Phone", dto.label)
    }

    @Test
    fun `the launcher leaves the phone as essential`() {
        assertTrue(inventoryApp(launcher, "Home", isSystem = true, facts = facts).essential)
    }

    @Test
    fun `an ordinary app leaves the phone as not essential`() {
        assertFalse(inventoryApp(browser, "Browser", isSystem = false, facts = facts).essential)
    }

    @Test
    fun `the wire value is the shared rule, not a second opinion`() {
        // Whatever the set decides, the inventory says: one implementation, so a change to
        // EssentialPackages cannot leave the picker and the enforcement disagreeing.
        for (pkg in listOf(dialer, launcher, browser)) {
            assertEquals(
                com.familyshield.agent.enforcement.EssentialPackages.isEssential(pkg, facts),
                inventoryApp(pkg, pkg, isSystem = false, facts = facts).essential,
            )
        }
    }
}
