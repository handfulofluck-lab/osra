package com.familyshield.agent.security

/**
 * Matches an accessibility service against `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES`.
 *
 * The stored value is a `:`-separated list of flattened component names, and Android writes the
 * class either fully qualified (`pkg/com.example.pkg.Svc`) or relative (`pkg/.Svc`); some entries
 * also carry a `:subId` suffix. This mirrors `android.content.ComponentName.unflattenFromString`
 * semantics: split on '/', prepend the package when the class starts with '.', and use the class
 * verbatim otherwise. A match requires both the package and the fully-qualified class to be equal,
 * so another package's service — or a different service in our own package — never counts.
 *
 * Pure Kotlin on purpose: `ComponentName` is stubbed in plain JVM unit tests (there is no
 * Robolectric here), so the parser must not call it.
 */
object AccessibilityServiceListPolicy {

    /** True when [flattenedComponent] (`pkg/Class` or `pkg/.Class`) appears in [enabledServices]. */
    fun isEnabled(enabledServices: String?, flattenedComponent: String): Boolean {
        val expected = parseComponent(flattenedComponent) ?: return false
        return isEnabled(enabledServices, expected.first, expected.second)
    }

    /** True when [packageName]/[className] appears in the `:`-separated [enabledServices] list. */
    fun isEnabled(enabledServices: String?, packageName: String, className: String): Boolean {
        if (enabledServices.isNullOrBlank()) return false
        val expected = fullyQualified(packageName, className)
        return enabledServices.split(':')
            .mapNotNull { parseComponent(it.trim()) }
            .any { (pkg, cls) -> pkg == packageName && cls == expected }
    }

    /** Resolves one list entry to `package to fully-qualified-class`, or null when malformed. */
    private fun parseComponent(entry: String): Pair<String, String>? {
        val separator = entry.indexOf('/')
        if (separator <= 0 || separator == entry.lastIndex) return null
        val pkg = entry.substring(0, separator)
        val cls = fullyQualified(pkg, entry.substring(separator + 1))
        if (cls.isEmpty() || cls.endsWith(".")) return null
        return pkg to cls
    }

    /** `ComponentName`'s rule: a leading dot means "relative to the package", otherwise verbatim. */
    private fun fullyQualified(packageName: String, className: String): String =
        if (className.startsWith(".")) packageName + className else className
}
