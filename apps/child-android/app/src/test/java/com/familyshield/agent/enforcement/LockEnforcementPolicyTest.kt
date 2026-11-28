package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 1.3: when the persisted lock must be re-raised over the foreground window. */
class LockEnforcementPolicyTest {
    private val own = "com.familyshield.agent"

    private class FakeFacts(
        private val system: Set<String> = emptySet(),
        private val roles: Set<String> = emptySet(),
    ) : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = pkg in system
        override fun dialerRoleHolders(): Set<String> = roles
    }

    /** The call surfaces the OS ships, plus two stand-ins for an OEM nobody listed. */
    private val oemSystem = setOf(
        "com.samsung.android.emergency",
        "com.android.emergency",
        "com.google.android.emergency",
        "com.android.dialer",
        "com.google.android.dialer",
        "com.samsung.android.dialer",
        "com.android.incallui",
        "com.samsung.android.incallui",
        "com.google.android.incallui",
        "com.android.systemui",
        "com.android.phone",
        "com.samsung.android.phone",
        "com.someoem.emergency",
        "com.another.dialer",
    )
    private val facts = FakeFacts(system = oemSystem)

    @Test
    fun `locking modes are locked and paused only - legacy paused_internet is retired (#1240 B2)`() {
        assertTrue(LockEnforcementPolicy.isLockingMode("locked"))
        assertTrue(LockEnforcementPolicy.isLockingMode("paused"))
        assertFalse(LockEnforcementPolicy.isLockingMode("paused_internet"))
        assertTrue(LockEnforcementPolicy.isLegacyOverlayMode("paused_internet"))
        assertFalse(LockEnforcementPolicy.isLegacyOverlayMode("locked"))
        assertEquals(LockState.MODE_NONE, LockEnforcementPolicy.normalizeStoredMode("paused_internet"))
        assertEquals("locked", LockEnforcementPolicy.normalizeStoredMode("locked"))
        assertEquals("paused", LockEnforcementPolicy.normalizeStoredMode("paused"))
        assertFalse(LockEnforcementPolicy.isLockingMode("none"))
        assertFalse(LockEnforcementPolicy.isLockingMode("unlock"))
        assertFalse(LockEnforcementPolicy.isLockingMode(null))
    }

    @Test
    fun `re-raises over the launcher, recents, settings and other apps while locked but never for retired paused_internet`() {
        for (pkg in listOf("com.sec.android.app.launcher", "com.android.settings", "com.whatsapp", "com.google.android.youtube")) {
            assertTrue(pkg, LockEnforcementPolicy.shouldReraise("locked", pkg, own, facts))
            assertTrue(pkg, LockEnforcementPolicy.shouldReraise("paused", pkg, own, facts))
            assertFalse(pkg, LockEnforcementPolicy.shouldReraise("paused_internet", pkg, own, facts))
        }
    }

    @Test
    fun `never over a call, the emergency dialer, the system UI or itself, and never when not locked`() {
        for (pkg in listOf("com.samsung.android.incallui", "com.android.incallui", "com.android.emergency", "com.android.systemui", "com.google.android.dialer", own)) {
            assertFalse(pkg, LockEnforcementPolicy.shouldReraise("locked", pkg, own, facts))
        }
        assertFalse(LockEnforcementPolicy.shouldReraise("none", "com.whatsapp", own, facts))
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", null, own, facts))
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", "", own, facts))
    }

    /**
     * Issue #80: the exemption list was written against AOSP names, so the one device we test — a
     * Samsung Flip4 whose emergency dialer is `com.samsung.android.emergency` — had the overlay raised
     * over its own dialer while this suite was green. A missed OEM name blocks an emergency call, so the
     * table is explicit and the rule also matches the segment for names we have not seen.
     */
    @Test
    fun `every OEM emergency and dialer package stays reachable under lock`() {
        val packages = linkedMapOf(
            "Samsung Flip4 emergency dialer (the #80 case)" to "com.samsung.android.emergency",
            "AOSP emergency" to "com.android.emergency",
            "Google emergency" to "com.google.android.emergency",
            "AOSP dialer" to "com.android.dialer",
            "Google dialer" to "com.google.android.dialer",
            "Samsung dialer" to "com.samsung.android.dialer",
            "AOSP in-call UI" to "com.android.incallui",
            "Samsung in-call UI" to "com.samsung.android.incallui",
            "Google in-call UI" to "com.google.android.incallui",
            "system UI" to "com.android.systemui",
            "telephony" to "com.android.phone",
            "Samsung telephony" to "com.samsung.android.phone",
            "an OEM nobody listed yet" to "com.someoem.emergency",
            "another OEM gesture dialer" to "com.another.dialer",
        )
        for ((label, pkg) in packages) {
            assertFalse("$label ($pkg) must stay reachable", LockEnforcementPolicy.shouldReraise("locked", pkg, own, facts))
            assertTrue("$label ($pkg) is exempt", LockEnforcementPolicy.isExemptPackage(pkg, facts))
        }
    }

    @Test
    fun `the segment rule does not exempt ordinary apps that merely mention those words`() {
        val mustLock = listOf(
            "com.whatsapp",
            "com.instagram.android",
            "com.example.emergencygame", // a game, not a dialer: segment equality, not substring
            "com.example.dialerapp",
            "com.example.phonebook",
        )
        for (pkg in mustLock) {
            assertTrue("$pkg must be locked", LockEnforcementPolicy.shouldReraise("locked", pkg, own, facts))
            assertFalse("$pkg is not exempt", LockEnforcementPolicy.isExemptPackage(pkg, facts))
        }
        assertFalse("own app", LockEnforcementPolicy.shouldReraise("locked", own, own, facts))
    }

    /**
     * Review of #83, F1 (blocking): the segment fallback matched a name the child chooses, so any app
     * called `com.anything.dialer` escaped the lock. Each of these must fail on `f338412` — where the
     * name alone was enough — and pass here, where a name only counts for a system app.
     */
    @Test
    fun `a name the child can choose is not a lock exemption`() {
        val namedButNotSystem = listOf(
            "com.evil.dialer", // a Play Store app can call itself this
            "com.android.phonebook.game", // startsWith("com.android.phone") before the boundary fix
            "com.anything.emergency",
            "com.example.incallui",
        )
        val noSystemFacts = FakeFacts(system = emptySet())
        for (pkg in namedButNotSystem) {
            assertTrue("$pkg must be locked", LockEnforcementPolicy.shouldReraise("locked", pkg, own, noSystemFacts))
            assertFalse("$pkg is not exempt", LockEnforcementPolicy.isExemptPackage(pkg, noSystemFacts))
        }
    }

    /** Review of #83, F1: the OS's dialer role outranks every name, including one no list contains. */
    @Test
    fun `the OS-assigned dialer role is exempt even when no list matches`() {
        val roleFacts = FakeFacts(system = emptySet(), roles = setOf("com.example.oemphone"))
        assertFalse(
            "a role holder must stay reachable",
            LockEnforcementPolicy.shouldReraise("locked", "com.example.oemphone", own, roleFacts),
        )
        assertTrue(LockEnforcementPolicy.isExemptPackage("com.example.oemphone", roleFacts))
        // The same package without the role and without the system flag is an ordinary app.
        assertTrue(
            LockEnforcementPolicy.shouldReraise("locked", "com.example.oemphone", own, FakeFacts()),
        )
    }

    /**
     * osra-security#95: own-package non-enforcement activities (such as Child Home `PairingActivity`)
     * must trigger lock re-raise, while enforcement/security screens stay exempt even when
     * `applicationId` (`com.osratech.child.full`) differs from namespace (`com.familyshield.agent`).
     *
     * Mutant that breaks this test: reverting `LockEnforcementPolicy.shouldReraise` to blanket
     * `if (foregroundPackage == ownPackage) return false` or `active != ownPackage`.
     */
    @Test
    fun `own-package Child Home triggers lock reraise while enforcement screens stay exempt`() {
        val prodOwn = "com.osratech.child.full"
        val pairingClass = "com.familyshield.agent.setup.PairingActivity"
        val pairingSnap = WindowSnapshot(
            activePackage = prodOwn,
            windows = listOf(VisibleWindow(prodOwn, inPictureInPicture = false)),
        )
        assertTrue(
            "PairingActivity (single-package) must trigger lock reraise",
            LockEnforcementPolicy.shouldReraise("locked", prodOwn, prodOwn, facts, ownWindowClass = pairingClass),
        )
        assertTrue(
            "PairingActivity (paused, single-package) must trigger lock reraise",
            LockEnforcementPolicy.shouldReraise("paused", prodOwn, prodOwn, facts, ownWindowClass = pairingClass),
        )
        assertTrue(
            "PairingActivity (WindowSnapshot) must trigger lock reraise",
            LockEnforcementPolicy.shouldReraise("locked", pairingSnap, prodOwn, facts, ownWindowClass = pairingClass),
        )
        assertFalse(
            "PairingActivity when unlocked must not trigger reraise",
            LockEnforcementPolicy.shouldReraise("none", pairingSnap, prodOwn, facts, ownWindowClass = pairingClass),
        )
        for (exemptClass in LockEnforcementPolicy.LOCK_EXEMPT_OWN_CLASSES) {
            assertFalse(
                "$exemptClass (single-package) must stay exempt",
                LockEnforcementPolicy.shouldReraise("locked", prodOwn, prodOwn, facts, ownWindowClass = exemptClass),
            )
            assertFalse(
                "$exemptClass (WindowSnapshot) must stay exempt",
                LockEnforcementPolicy.shouldReraise("locked", pairingSnap, prodOwn, facts, ownWindowClass = exemptClass),
            )
        }
    }

    /**
     * osra-security#95: `OverlayRetryBudget.reset()` re-arms after exhaustion so keyguard dismissal
     * gets a fresh retry budget.
     *
     * Mutant that breaks this test: removing `reset()` or failing to clear `attempts` / `signature`.
     */
    @Test
    fun `OverlayRetryBudget reset re-arms after exhaustion`() {
        val budget = OverlayRetryBudget(maxAttempts = 2)
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("sig-a"))
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("sig-a"))
        assertEquals(RetryDecision.EXHAUSTED_ONCE, budget.attempt("sig-a"))
        budget.reset()
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("sig-a"))
    }

    /**
     * osra-security#95: wiring check on `AccessibilityMonitorService` — own-package branch runs
     * `enforceLockState` before returning, `enforceLockState` defers while keyguard is locked, and
     * `ACTION_USER_PRESENT` is registered to re-arm and check lock after keyguard dismissal.
     *
     * Mutant that breaks this test: deleting any of the three hooks in `AccessibilityMonitorService.kt`.
     */
    @Test
    fun `AccessibilityMonitorService wires own-package lock enforcement, keyguard check, and ACTION_USER_PRESENT`() {
        val serviceFile = java.io.File("src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
            .takeIf { it.isFile }
            ?: java.io.File("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        val src = serviceFile.readText()
        val ownBranch = src.substringAfter("if (eventPkg == packageName) {").substringBefore("val snapshot = windowSnapshot()")
        assertTrue(
            "own-package branch must call enforceLockState before return",
            ownBranch.contains("enforceLockState(windowSnapshot(), packageName)"),
        )
        val enforceLockFn = src.substringAfter("private fun enforceLockState(").substringBefore("private fun collectTexts(")
        assertTrue(
            "enforceLockState must skip while keyguard is locked",
            enforceLockFn.contains("isKeyguardLocked == true"),
        )
        assertTrue(
            "screenFilter must register ACTION_USER_PRESENT",
            src.contains("addAction(Intent.ACTION_USER_PRESENT)"),
        )
        assertTrue(
            "onUserPresentLockCheck must reset lockRetryBudget",
            src.contains("lockRetryBudget.reset()"),
        )
    }
}
