package com.familyshield.agent.enforcement

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.telecom.TelecomManager
import java.util.concurrent.ConcurrentHashMap

/**
 * What the OS says a package *is*, so the lock exemption never trusts a name the child can choose.
 *
 * Issue #80's fix first matched package names (prefixes plus an `emergency`/`dialer`/`incallui`
 * segment), which kept the OEM dialer reachable but also handed a lock bypass to anyone who published
 * an app called `com.anything.dialer`. The review of #83 (F1) named it: exempt by role and by system
 * flag, and keep the name table only as a fallback for packages the OS also calls system.
 */
interface PackageFacts {
    /** `ApplicationInfo.FLAG_SYSTEM` or `FLAG_UPDATED_SYSTEM_APP` — an app the user cannot simply replace. */
    fun isSystemApp(pkg: String): Boolean

    /** Packages the OS has made the dialer: the telecom defaults and the system handlers of the call intents. */
    fun dialerRoleHolders(): Set<String>

    /**
     * Packages that answer the HOME intent — the launcher, whatever the OEM calls it (issue #165).
     * A default is provided so a test double that only cares about call surfaces stays valid.
     */
    fun homePackages(): Set<String> = emptySet()

    /** Drops any cached answers; the accessibility service calls it when a package is installed/removed. */
    fun refresh() = Unit
}

/**
 * [PackageFacts] backed by PackageManager/TelecomManager, with both lookups cached: the accessibility
 * service asks on every window event, so an uncached version would do binder calls in a hot path.
 */
class AndroidPackageFacts(private val context: Context) : PackageFacts {
    private val systemCache = ConcurrentHashMap<String, Boolean>()

    @Volatile
    private var roles: Set<String>? = null

    @Volatile
    private var homes: Set<String>? = null

    override fun isSystemApp(pkg: String): Boolean = systemCache.getOrPut(pkg) {
        runCatching {
            val info = context.packageManager.getApplicationInfo(pkg, 0)
            (info.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0
        }.getOrDefault(false)
    }

    override fun dialerRoleHolders(): Set<String> {
        roles?.let { return it }
        synchronized(this) {
            roles?.let { return it }
            val computed = computeRoleHolders()
            roles = computed
            return computed
        }
    }

    /** Issue #165: the current HOME handler is the launcher, and no package knows its OEM name in advance. */
    override fun homePackages(): Set<String> {
        homes?.let { return it }
        synchronized(this) {
            homes?.let { return it }
            val computed = runCatching {
                context.packageManager.queryIntentActivities(
                    Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                    0,
                ).mapNotNull { it.activityInfo?.packageName }.toSet()
            }.getOrDefault(emptySet())
            homes = computed
            return computed
        }
    }

    /** Drop every cache — called when a package is installed, replaced or removed. */
    override fun refresh() {
        roles = null
        homes = null
        systemCache.clear()
    }

    private fun computeRoleHolders(): Set<String> {
        val out = linkedSetOf<String>()
        runCatching {
            context.getSystemService(TelecomManager::class.java)?.defaultDialerPackage
        }.getOrNull()?.let(out::add)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                context.getSystemService(TelecomManager::class.java)?.systemDialerPackage
            }.getOrNull()?.let(out::add)
        }
        out.addAll(systemHandlers(EmergencyDialerIntent))
        out.addAll(systemHandlers(Intent(Intent.ACTION_DIAL)))
        return out
    }

    private fun systemHandlers(intent: Intent): List<String> = runCatching {
        context.packageManager.queryIntentActivities(intent, 0)
            .mapNotNull { it.activityInfo?.packageName }
            .distinct()
            .filter { isSystemApp(it) }
    }.getOrDefault(emptyList())

    private companion object {
        /** The AOSP emergency-dialer intent; Samsung and Google both answer it. */
        val EmergencyDialerIntent = Intent("com.android.phone.EmergencyDialer.DIAL")
    }
}
