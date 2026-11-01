package com.familyshield.agent.security

import android.content.Context
import android.content.pm.LauncherApps
import android.os.Build
import android.os.Process
import android.os.UserManager

/**
 * osra-security#6 item 2: reads the other profiles on this phone for [ProfilePolicy].
 *
 * Not wired into a request yet: the capability report's transport is ADR-0034 PR 2, which calls [read]
 * and puts the result in `capabilities.profiles`. Until the phone session confirms on the Flip4 that
 * `UserManager.getUserProfiles()` returns Dual Messenger's user 95 to a normal app (its flags carry
 * `PROFILE`, and `getUserProfiles` needs no permission), this is the claim under test, not a fact.
 *
 * Returns null when the profiles cannot be read at all, so the report omits `profiles` and the server
 * keeps the last value rather than storing a false "no other space".
 */
class ProfileReader(private val context: Context) {

    fun read(): ProfilePolicy.Report? = try {
        val userManager = context.getSystemService(UserManager::class.java)
        val me = Process.myUserHandle()
        val others = userManager.userProfiles.filter { it != me }
        val sdk = Build.VERSION.SDK_INT
        val types: List<String?> = if (sdk >= ProfilePolicy.TYPE_READABLE_FROM_SDK) {
            val launcherApps = context.getSystemService(LauncherApps::class.java)
            // A type the platform will not tell us is `other`, never a missing profile.
            others.map { user -> runCatching { launcherApps.getLauncherUserInfo(user)?.userType }.getOrNull() }
        } else {
            others.map { null }
        }
        ProfilePolicy.report(types, sdk)
    } catch (t: Throwable) {
        null
    }
}
