package com.familyshield.agent.network

/**
 * ADR-0034 decision 4 + 5 (amendment A3): the value of `X-OSRA-Client`, computed rather than assembled.
 *
 * The server reads exactly one shape — `app/<major>.<minor>.<patch>+<build> (<flavour>)`, at most 64
 * characters, every version part 1–4 digits and the flavour `[a-z0-9-]{1,16}` — and **anything else is
 * legacy**: it is served exactly as an unversioned client is, which is what keeps every build released
 * before this change working (decision 4, claim 7).
 *
 * So this returns **null rather than a guess**. A version name that cannot be told truthfully in the shape
 * (`0.2`, `0.2.0-rc1` with a non-numeric part, a part longer than four digits) produces no header at all,
 * because a wrong build number is worse than none: the update gate reads the number, and the server cannot
 * tell a typo from a real release.
 *
 * Kept pure and Android-free so the JVM suite pins the string; [ClientHeaderInterceptor] is the adapter.
 */
object ClientHeader {

    /** The header the server parses (`services/api/src/lib/clientHeader.ts`). */
    const val NAME = "X-OSRA-Client"

    /** A3's hard cap. A longer value is not sent, rather than sent and rejected. */
    const val MAX_LENGTH = 64

    /** The app name this artefact reports: the only one the server knows for an Android child agent. */
    const val APP = "child-android"

    /** The two artefacts of ADR-0016 §4, which are also the two `CAPABILITY_FLAVOURS` Android has. */
    const val FLAVOUR_PLAY = "play"
    const val FLAVOUR_FULL = "full"

    private val VERSION_PART = Regex("^\\d{1,4}$")
    private val FLAVOUR = Regex("^[a-z0-9-]{1,16}$")

    /**
     * The header value for this build, or null when it cannot be expressed exactly.
     *
     * @param versionName `BuildConfig.VERSION_NAME`, e.g. `0.2.0`
     * @param versionCode `BuildConfig.VERSION_CODE` — the integer that orders releases
     * @param flavour `play` or `full`
     */
    fun value(versionName: String?, versionCode: Int, flavour: String): String? {
        val version = semver(versionName) ?: return null
        if (versionCode < 1) return null
        if (!FLAVOUR.matches(flavour)) return null
        val header = "$APP/$version+$versionCode ($flavour)"
        return header.takeIf { it.length <= MAX_LENGTH }
    }

    /**
     * `0.2.0` from `0.2.0`, or `0.2.0` from `0.2` by padding the missing parts with zeros — Gradle allows a
     * two-part name and the wire does not. A part that is not 1–4 digits is not a version we can claim.
     */
    private fun semver(versionName: String?): String? {
        val raw = versionName?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val parts = raw.split('.')
        if (parts.size > 3) return null
        if (parts.any { !VERSION_PART.matches(it) }) return null
        return (parts + List(3 - parts.size) { "0" }).joinToString(".")
    }
}
