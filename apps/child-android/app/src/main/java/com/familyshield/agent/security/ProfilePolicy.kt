package com.familyshield.agent.security

/**
 * osra-security#6 item 2: the `profiles` part of the ADR-0034 capability report — how many other users
 * or profiles the phone holds besides the child's own, and of which kinds. **Counts and kinds only**: no
 * user id, name or app list leaves the phone.
 *
 * Pure, so the JVM tests reach it; [ProfileReader] gathers the inputs. The vocabulary and its rules are
 * the server's (`packages/shared-types` `PROFILE_KINDS`, the API's strict `ProfilesSchema`):
 *  - `kinds` is a set, in vocabulary order, with at most `others` entries;
 *  - `others > 0` never sends an empty `kinds`: a profile whose type we cannot name is `other`, so the
 *    parent's Phone setup row cannot read as clean;
 *  - `others` is capped at [MAX_OTHERS].
 *
 * The user type is readable by a normal app only from API 35 (`LauncherApps.getLauncherUserInfo`); below
 * that every profile is `other`. The Flip4 capture on #6 (SDK 36) showed Dual Messenger's user 95 as
 * [TYPE_CLONE]. `secure_folder` stays unmapped until a capture shows a set-up Secure Folder's type.
 */
object ProfilePolicy {

    /** What the report carries. [kinds] holds wire names from [KINDS]. */
    data class Report(val others: Int, val kinds: List<String>)

    const val TYPE_CLONE = "android.os.usertype.profile.CLONE"
    const val TYPE_MANAGED = "android.os.usertype.profile.MANAGED"

    /** The server's `PROFILE_KINDS`, in its order. */
    val KINDS = listOf("work", "clone", "secure_folder", "other")

    /** The server's `PROFILES_MAX_OTHERS`. */
    const val MAX_OTHERS = 8

    /** The first API level where a normal app can read another profile's user type. */
    const val TYPE_READABLE_FROM_SDK = 35

    /** The kind one profile is reported as, from its user type (null when it could not be read). */
    fun kindOf(userType: String?, sdkInt: Int): String {
        if (sdkInt < TYPE_READABLE_FROM_SDK) return "other"
        return when (userType) {
            TYPE_CLONE -> "clone"
            TYPE_MANAGED -> "work"
            else -> "other"
        }
    }

    /**
     * The report for the profiles other than the child's own. [otherUserTypes] has one entry per other
     * profile — its user type, or null when it could not be read.
     */
    fun report(otherUserTypes: List<String?>, sdkInt: Int): Report {
        val others = otherUserTypes.size.coerceAtMost(MAX_OTHERS)
        if (others == 0) return Report(0, emptyList())
        val seen = otherUserTypes.map { kindOf(it, sdkInt) }.toSet()
        // Filtering the vocabulary makes the set and the order at once. It cannot exceed `others`: each
        // profile adds at most one kind, and the cap leaves at least as many profiles as there are kinds.
        return Report(others, KINDS.filter { it in seen })
    }
}
