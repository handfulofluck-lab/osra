package com.familyshield.agent.ui.theme

import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #728: the theme's two halves, judged where a JVM can judge them.
 *
 * **The tokens themselves are checked by the generator, not here.** `node scripts/gen-android-tokens.mjs
 * --check` fails when `OsraTokens.kt` no longer matches `docs/design/tokens.json`, and it runs in
 * `workflow-lint` beside the other repository checks — so a colour nudged by hand is a red CI job, and this file
 * does not re-implement a JSON parser to say the same thing badly.
 *
 * What is left for these rows is the **mapping**, which the generator cannot check: does a screen that asks
 * Material for `primary` get the design's primary, does it get the design's type sizes on the slots it will
 * reach for, and do the two themes really differ.
 *
 * Mutants: point `colors()` at a hardcoded colour → [every Material slot comes from the palette]; swap the light
 * and dark palettes in `OsraTheme` → [the two themes are different where the design says so]; hand-write a
 * `TextStyle` instead of reading the token → [the type sizes are the design file's].
 */
class OsraThemeTokensTest {

    @Test
    fun `every Material slot comes from the palette`() {
        for (palette in listOf(OsraTokens.light, OsraTokens.dark)) {
            val scheme = OsraTheme.colors(palette, dark = palette === OsraTokens.dark)
            assertEquals("primary", palette.primary, scheme.primary)
            assertEquals("onPrimary", palette.onPrimary, scheme.onPrimary)
            assertEquals("background", palette.page, scheme.background)
            assertEquals("onBackground", palette.ink, scheme.onBackground)
            assertEquals("surface", palette.card, scheme.surface)
            assertEquals("onSurface", palette.ink, scheme.onSurface)
            assertEquals("error", palette.danger, scheme.error)
            assertEquals("outline", palette.border, scheme.outline)
            assertEquals("scrim", palette.scrim, scheme.scrim)
        }
    }

    @Test
    fun `the two themes are different where the design says so`() {
        assertNotEquals("a light page is not a dark page", OsraTokens.light.page, OsraTokens.dark.page)
        assertNotEquals("and the action colour flips", OsraTokens.light.primary, OsraTokens.dark.primary)
        // The dark card carries an outline; the light one does not (the design's `transparent`).
        assertNotEquals("the dark card has a border", OsraTokens.dark.cardBorder, OsraTokens.light.cardBorder)
    }

    @Test
    fun `the type sizes are the design file's`() {
        val type = OsraTheme.typography()
        assertEquals("screenTitle sits on headlineMedium", 26.sp, type.headlineMedium.fontSize)
        assertEquals("its line height", 32.sp, type.headlineMedium.lineHeight)
        assertEquals("its weight", FontWeight(700), type.headlineMedium.fontWeight)
        assertEquals("body sits on bodyLarge", 15.sp, type.bodyLarge.fontSize)
        assertEquals("rowTitle is the 600 label", FontWeight(600), type.labelLarge.fontWeight)
        assertEquals("bigNumber is the display", 48.sp, type.displayLarge.fontSize)
    }

    @Test
    fun `the radii are per theme`() {
        assertEquals("a light card is 18", 18, OsraTokens.lightRadii.card.value.toInt())
        assertEquals("a dark card is 12", 12, OsraTokens.darkRadii.card.value.toInt())
        val light = OsraTheme.shapes(OsraTokens.lightRadii)
        val dark = OsraTheme.shapes(OsraTokens.darkRadii)
        assertNotEquals("the two shape sets differ", light.large, dark.large)
    }

    @Test
    fun `the generated tokens carry the design's font names`() {
        assertEquals("IBM Plex Sans", OsraTokens.FONT_LATIN)
        assertEquals("IBM Plex Sans Arabic", OsraTokens.FONT_ARABIC)
        assertTrue("the families are named, not left to the system", OsraTokens.FONT_LATIN.isNotBlank())
    }
}
