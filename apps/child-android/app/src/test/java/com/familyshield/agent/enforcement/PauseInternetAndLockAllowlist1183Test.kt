package com.familyshield.agent.enforcement

import com.familyshield.agent.commands.AlwaysAllowedShortcut
import com.familyshield.agent.commands.LockAlwaysAllowedPolicy
import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RuleSetDto
import java.io.File
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1183 (Saturday Android scope):
 * 1. Pause internet is network-only: VPN sinkhole stays active, offline apps stay open in
 *    [RuleEngine], no full-screen [LockActivity] overlay is launched, and a non-blocking ongoing
 *    notification is shown until `resume_internet` cancels it (without touching an independent
 *    device lock).
 * 2. Always-allowed apps stay usable under Lock: [LockEnforcementPolicy] exempts
 *    `ruleSet.alwaysAllowedApps` when alone on screen (while still re-raising if a non-allowed app
 *    shares split-screen or PiP), and [LockActivity] exposes launchable always-allowed shortcuts.
 */
class PauseInternetAndLockAllowlist1183Test {

    private val own = "com.familyshield.agent"
    private val eduApp = "com.edu.khan"
    private val phoneApp = "com.whatsapp"
    private val gameApp = "com.game.blocked"
    private val launcher = "com.sec.android.app.launcher"
    private val dialer = "com.samsung.android.dialer"

    private class FakeFacts(
        private val system: Set<String> = emptySet(),
        private val roles: Set<String> = emptySet(),
        private val homes: Set<String> = emptySet(),
    ) : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = pkg in system
        override fun dialerRoleHolders(): Set<String> = roles
        override fun homePackages(): Set<String> = homes
    }

    private val facts = FakeFacts(
        system = setOf(dialer, "com.android.systemui"),
        homes = setOf(launcher),
    )

    private fun noonSaturday(): ZonedDateTime {
        val date = LocalDate.now().with(TemporalAdjusters.nextOrSame(DayOfWeek.SATURDAY))
        return ZonedDateTime.of(date, LocalTime.of(12, 0), ZoneOffset.UTC)
    }

    @Test
    fun `RuleEngine leaves offline apps open when pausedInternet is true while keeping explicit blocks`() {
        val engine = RuleEngine()
        val rules = RuleSetDto(
            alwaysAllowedApps = listOf(eduApp),
            appRules = listOf(AppRuleDto(packageId = gameApp, appName = "Game", action = "block")),
        )
        assertEquals(Decision.ALLOW, engine.evaluate(rules, eduApp, noonSaturday(), pausedInternet = true))
        assertEquals(Decision.ALLOW, engine.evaluate(rules, phoneApp, noonSaturday(), pausedInternet = true))
        assertEquals(Decision.BLOCK, engine.evaluate(rules, gameApp, noonSaturday(), pausedInternet = true))
    }

    @Test
    fun `LockEnforcementPolicy exempts always-allowed apps under Lock while blocking non-allowed apps`() {
        val allowed = setOf(eduApp, phoneApp)
        assertFalse(
            "always-allowed app must stay open under Lock (single-package form)",
            LockEnforcementPolicy.shouldReraise("locked", eduApp, own, facts, allowed),
        )
        assertFalse(
            "always-allowed app must stay open under Pause (single-package form)",
            LockEnforcementPolicy.shouldReraise("paused", phoneApp, own, facts, allowed),
        )
        assertTrue(
            "non-allowed game must still raise Lock",
            LockEnforcementPolicy.shouldReraise("locked", gameApp, own, facts, allowed),
        )
        assertTrue(
            "launcher must still raise Lock so child cannot browse blocked apps",
            LockEnforcementPolicy.shouldReraise("locked", launcher, own, facts, allowed),
        )
    }

    @Test
    fun `LockEnforcementPolicy multi-window allows solo always-allowed app but blocks split-screen bypass`() {
        val allowed = setOf(eduApp)
        val soloAllowed = WindowSnapshot(
            activePackage = eduApp,
            windows = listOf(VisibleWindow("com.android.systemui"), VisibleWindow(eduApp)),
        )
        assertFalse(
            "solo always-allowed app plus system UI must not raise Lock",
            LockEnforcementPolicy.shouldReraise("locked", soloAllowed, own, facts, allowed),
        )

        // Security invariant (#175 + #1183): an active always-allowed app in one half of split-screen
        // must NOT shield a non-allowed game visible in the other half or in PiP.
        val splitBypass = WindowSnapshot(
            activePackage = eduApp,
            windows = listOf(VisibleWindow(eduApp), VisibleWindow(gameApp)),
        )
        assertTrue(
            "always-allowed app beside a blocked game in split-screen MUST raise Lock",
            LockEnforcementPolicy.shouldReraise("locked", splitBypass, own, facts, allowed),
        )

        val pipBypass = WindowSnapshot(
            activePackage = eduApp,
            windows = listOf(VisibleWindow(eduApp), VisibleWindow(gameApp, inPictureInPicture = true)),
        )
        assertTrue(
            "always-allowed app with blocked game in PiP MUST raise Lock",
            LockEnforcementPolicy.shouldReraise("locked", pipBypass, own, facts, allowed),
        )

        // Emergency call still wins over any other visible window (#80).
        val emergencyWithGame = WindowSnapshot(
            activePackage = dialer,
            windows = listOf(VisibleWindow(dialer), VisibleWindow(gameApp)),
        )
        assertFalse(
            "emergency dialer stays uncovered even if another window is visible",
            LockEnforcementPolicy.shouldReraise("locked", emergencyWithGame, own, facts, allowed),
        )
    }

    @Test
    fun `Ahmed R3 hard deny-set blocks Settings, OEM security, installers, Play Store and launchers even when always-allowed`() {
        val deniedCandidates = listOf(
            "com.android.settings",
            "com.samsung.android.settings",
            "com.miui.securitycenter",
            "com.coloros.safecenter",
            "com.google.android.packageinstaller",
            "com.android.packageinstaller",
            "com.miui.packageinstaller",
            "com.android.vending",
            launcher,
        )
        val parentAllowlist = deniedCandidates + listOf(phoneApp, eduApp)
        val allowSet = parentAllowlist.toSet()

        // 1. Denied packages in alwaysAllowedApps -> NO shortcut under Lock AND Lock re-raises over them.
        for (denied in deniedCandidates) {
            assertTrue(
                "$denied must be denied from Lock allowlist even if parent added it",
                LockEnforcementPolicy.isLockAllowlistDenied(denied, setOf(launcher)),
            )
            assertFalse(
                "$denied must NOT be exempt under Lock",
                LockEnforcementPolicy.isExemptPackage(denied, facts, allowSet),
            )
            assertTrue(
                "Lock must re-raise over $denied (single-package form)",
                LockEnforcementPolicy.shouldReraise("locked", denied, own, facts, allowSet),
            )
            val snap = WindowSnapshot(activePackage = denied, windows = listOf(VisibleWindow(denied)))
            assertTrue(
                "Lock must re-raise over $denied (multi-window form)",
                LockEnforcementPolicy.shouldReraise("locked", snap, own, facts, allowSet),
            )
        }

        // 2. Normal allowed apps -> shortcut IS shown AND Lock stays open for them.
        val shortcuts = LockAlwaysAllowedPolicy.resolveLaunchable(
            alwaysAllowedPackages = parentAllowlist,
            ownPackage = own,
            homePackages = setOf(launcher),
            resolveLabel = { pkg ->
                when (pkg) {
                    phoneApp -> "WhatsApp"
                    eduApp -> "Khan Academy"
                    "com.android.settings" -> "Settings"
                    "com.android.vending" -> "Play Store"
                    launcher -> "One UI Home"
                    else -> pkg
                }
            },
        )
        assertEquals(
            "Shortcuts must include only normal allowed apps and exclude all denied system/launcher packages",
            listOf(
                AlwaysAllowedShortcut(eduApp, "Khan Academy"),
                AlwaysAllowedShortcut(phoneApp, "WhatsApp"),
            ),
            shortcuts,
        )
        assertFalse(
            "Normal allowed messaging app stays open under Lock",
            LockEnforcementPolicy.shouldReraise("locked", phoneApp, own, facts, allowSet),
        )
    }

    @Test
    fun `LockAlwaysAllowedPolicy filters blanks, own package, uninstalled apps, and sorts by label`() {
        val labels = mapOf(
            phoneApp to "WhatsApp",
            eduApp to "Khan Academy",
            own to "OSRA",
        )
        val shortcuts = LockAlwaysAllowedPolicy.resolveLaunchable(
            alwaysAllowedPackages = listOf("", "  ", own, phoneApp, "com.not.installed", eduApp, eduApp),
            ownPackage = own,
            resolveLabel = { labels[it] },
        )
        assertEquals(
            listOf(
                AlwaysAllowedShortcut(eduApp, "Khan Academy"),
                AlwaysAllowedShortcut(phoneApp, "WhatsApp"),
            ),
            shortcuts,
        )
    }

    @Test
    fun `wiring pins network-only pauseInternet, safe resumeInternet, lock allowlist, and EN-AR strings`() {
        val root = findAppSrcRoot()
        val dispatcher = File(root, "java/com/familyshield/agent/commands/CommandDispatcher.kt").readText()
        val service = File(root, "java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val lockActivity = File(root, "java/com/familyshield/agent/commands/LockActivity.kt").readText()
        val unlinker = File(root, "java/com/familyshield/agent/network/DeviceUnlinker.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        val pauseFn = dispatcher.substringAfter("private fun pauseInternet(): CommandOutcome {")
            .substringBefore("private fun resumeInternet()")
        assertTrue("pauseInternet must keep VPN sinkhole", pauseFn.contains("MODE_SINKHOLE_ALL"))
        assertTrue("pauseInternet must show non-blocking notice", pauseFn.contains("postPausedInternetNotification()"))
        assertFalse("pauseInternet must NOT set LockState", pauseFn.contains("LockState.set("))
        assertFalse("pauseInternet must NOT start LockActivity overlay", pauseFn.contains("LockActivity::class.java"))

        val resumeFn = dispatcher.substringAfter("private fun resumeInternet() {")
            .substringBefore("private fun postPausedInternetNotification()")
        assertTrue("resumeInternet must cancel paused-internet notice", resumeFn.contains("cancelPausedInternetNotification(context)"))
        assertTrue(
            "resumeInternet must only clear LockState if stored mode is MODE_PAUSED_INTERNET",
            resumeFn.contains("LockState.mode(context) == LockActivity.MODE_PAUSED_INTERNET"),
        )
        assertTrue("DeviceUnlinker must cancel paused-internet notice", unlinker.contains("cancelPausedInternetNotification(context)"))

        val enforceLockFn = service.substringAfter("private fun enforceLockState(")
            .substringBefore("private fun collectTexts(")
        assertTrue("enforceLockState must read alwaysAllowedApps", enforceLockFn.contains("alwaysAllowedApps"))
        assertTrue("enforceLockState must pass alwaysAllowed to LockEnforcementPolicy", enforceLockFn.contains("shouldReraise(mode, snapshot, packageName, packageFacts, alwaysAllowed)"))

        assertTrue("LockActivity must resolve launchable always-allowed shortcuts", lockActivity.contains("LockAlwaysAllowedPolicy.resolveLaunchable("))
        assertTrue("LockActivity must render heading string resource", lockActivity.contains("R.string.lock_always_allowed_heading"))

        for (key in listOf("notification_paused_internet_body", "lock_always_allowed_heading")) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
        }
    }

    private fun findAppSrcRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(5) {
            val candidate = File(dir, "src/main")
            if (candidate.isDirectory) return candidate
            val nested = File(dir, "app/src/main")
            if (nested.isDirectory) return nested
            dir = dir.parentFile ?: return candidate
        }
        return File("src/main")
    }
}
