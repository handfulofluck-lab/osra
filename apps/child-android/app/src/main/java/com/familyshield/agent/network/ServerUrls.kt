package com.familyshield.agent.network

/** Pure helpers (no Android classes) for the tester-configurable server base URL (§14.2). */
object ServerUrls {

    /**
     * Normalizes a user-entered server URL: trims whitespace, prepends `http://` when the scheme
     * is missing (testers type `192.168.1.5:3000`), and strips trailing slashes so paths can be
     * appended safely. Returns the input unchanged (empty) when blank.
     */
    fun normalize(input: String): String {
        var s = input.trim()
        if (s.isEmpty()) return s
        if (!s.contains("://")) s = "http://$s"
        return s.trimEnd('/')
    }
}
