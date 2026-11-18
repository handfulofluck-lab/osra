package com.familyshield.agent.security

/**
 * The gate's two colours, in one place so a Bureau token swap touches nothing else — and so the contrast
 * rule can be a JVM test rather than a sentence in a review (#792, Codex's finding: the error text measured
 * 2.37:1 against this background).
 *
 * The background is the gate's own dark surface; the error text is the Material dark-theme error role.
 */
object GuardPalette {
    /** The gate's background: `#0D1B2A`. */
    const val BACKGROUND = 0xFF0D1B2A.toInt()

    /** Error banner text: `#FFB4AB`, Material's dark error role. 10.24:1 on [BACKGROUND]. */
    const val ERROR_TEXT = 0xFFFFB4AB.toInt()

    /** WCAG 2.1 relative luminance of an opaque ARGB colour. */
    fun luminance(argb: Int): Double {
        fun channel(value: Int): Double {
            val c = value / 255.0
            return if (c <= 0.03928) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
        }
        val r = channel((argb shr 16) and 0xFF)
        val g = channel((argb shr 8) and 0xFF)
        val b = channel(argb and 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /** WCAG contrast ratio between two opaque colours, 1.0 … 21.0. */
    fun contrastRatio(a: Int, b: Int): Double {
        val la = luminance(a)
        val lb = luminance(b)
        val hi = maxOf(la, lb)
        val lo = minOf(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /** The Bureau's floor for normal body text on this screen. */
    const val MIN_BODY_CONTRAST = 4.5
}
