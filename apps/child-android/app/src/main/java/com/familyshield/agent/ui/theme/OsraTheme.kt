package com.familyshield.agent.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * The one theme for every OSRA Kids screen (roadmap #728, the UI/UX Bureau's design of 13 Nov).
 *
 * The values come from [OsraTokens], which is generated from `docs/design/tokens.json`; the mapping to Material
 * 3 lives here so a screen never picks a colour, a corner or a line height by hand. The palette is the design
 * file's two columns — no system blue, no Material grey — and the type scale is its nine steps.
 *
 * **Two deliberate gaps, both visible rather than silent:**
 * - **The font families are not bundled yet.** `OsraTokens.FONT_LATIN` / `FONT_ARABIC` name IBM Plex Sans and
 *   IBM Plex Sans Arabic; the files (SIL OFL) and their licence text belong in `res/` in the PR that draws the
 *   first screen, because a font added without its licence is a licensing problem, not a to-do. Until then
 *   [typography] uses [FontFamily.Default], and the Bureau will see the difference on the review picture.
 * - **`cardBorder` is a colour, not a stroke.** In the light theme it is `transparent` on purpose (cards carry
 *   no outline by day); a screen that wants the dark outline draws `border` with `CardDefaults` and reads
 *   `palette.cardBorder` itself.
 *
 * Everything here is a pure function of the tokens except [OsraTheme], so the mapping is JVM-tested
 * ([OsraThemeTokensTest]) rather than looked at.
 */
object OsraTheme {

    /**
     * The Material 3 scheme for one palette.
     *
     * Built through `lightColorScheme`/`darkColorScheme` rather than the `ColorScheme` constructor: the constructor
     * gains parameters between Compose versions, and a theme that stops compiling on a version bump is a worse
     * outcome than one leaving a slot at its default. Every slot the design file names is set below; the rest stay
     * at Material's value and no screen reads them.
     */
    fun colors(palette: OsraTokens.Palette, dark: Boolean): ColorScheme = if (dark) {
        darkColorScheme(
            primary = palette.primary, onPrimary = palette.onPrimary,
            primaryContainer = palette.tint, onPrimaryContainer = palette.ink,
            secondary = palette.raised, onSecondary = palette.ink,
            secondaryContainer = palette.tint, onSecondaryContainer = palette.ink,
            tertiary = palette.ok, onTertiary = palette.onPrimary,
            background = palette.page, onBackground = palette.ink,
            surface = palette.card, onSurface = palette.ink,
            surfaceVariant = palette.tint, onSurfaceVariant = palette.muted,
            surfaceTint = palette.primary,
            inverseSurface = palette.ink, inverseOnSurface = palette.page,
            error = palette.danger, onError = palette.onDanger,
            outline = palette.border, outlineVariant = palette.line,
            scrim = palette.scrim,
        )
    } else {
        lightColorScheme(
            primary = palette.primary, onPrimary = palette.onPrimary,
            primaryContainer = palette.tint, onPrimaryContainer = palette.ink,
            secondary = palette.raised, onSecondary = palette.ink,
            secondaryContainer = palette.tint, onSecondaryContainer = palette.ink,
            tertiary = palette.ok, onTertiary = palette.onPrimary,
            background = palette.page, onBackground = palette.ink,
            surface = palette.card, onSurface = palette.ink,
            surfaceVariant = palette.tint, onSurfaceVariant = palette.muted,
            surfaceTint = palette.primary,
            inverseSurface = palette.ink, inverseOnSurface = palette.page,
            error = palette.danger, onError = palette.onDanger,
            outline = palette.border, outlineVariant = palette.line,
            scrim = palette.scrim,
        )
    }

    /**
     * The nine steps of the design file, placed on the Material slots a screen actually reaches for. The
     * mapping is one-way on purpose: a screen asks for `headlineMedium` and gets 26/32/700, it does not ask for
     * "26 bold".
     */
    fun typography(family: FontFamily = FontFamily.Default): Typography {
        fun style(t: OsraTokens.TypeStyle) = TextStyle(
            fontFamily = family,
            fontSize = t.sizeSp.sp,
            lineHeight = t.lineSp.sp,
            fontWeight = FontWeight(t.weight),
        )
        val screenTitle = style(OsraTokens.screenTitle)
        val pageTitle = style(OsraTokens.pageTitle)
        val status = style(OsraTokens.status)
        val cardTitle = style(OsraTokens.cardTitle)
        val body = style(OsraTokens.body)
        val rowTitle = style(OsraTokens.rowTitle)
        val secondary = style(OsraTokens.secondary)
        val caption = style(OsraTokens.caption)
        val bigNumber = style(OsraTokens.bigNumber)
        return Typography(
            displayLarge = bigNumber,
            displayMedium = bigNumber,
            displaySmall = bigNumber,
            headlineLarge = screenTitle,
            headlineMedium = screenTitle,
            headlineSmall = pageTitle,
            titleLarge = pageTitle,
            titleMedium = cardTitle,
            titleSmall = rowTitle,
            bodyLarge = status,
            bodyMedium = body,
            bodySmall = secondary,
            labelLarge = rowTitle,
            labelMedium = secondary,
            labelSmall = caption,
        )
    }

    /** Corner radii from the tokens, per theme — the design shrinks them on dark surfaces on purpose. */
    fun shapes(radii: OsraTokens.Radii): Shapes = Shapes(
        extraSmall = RoundedCornerShape(radii.bar),
        small = RoundedCornerShape(radii.control),
        medium = RoundedCornerShape(radii.control),
        large = RoundedCornerShape(radii.card),
        extraLarge = RoundedCornerShape(radii.sheet),
    )

    /**
     * The palette and radii of the theme currently in force.
     *
     * Material's `ColorScheme` and `Shapes` carry what Material slots can express; the design file also has
     * `warn`, `ok`, `cardBorder`, `line` and per-theme radii, and a screen that named
     * `OsraTokens.light…` directly would draw a **dark** screen with the light corners — `PairingScreen.kt`
     * did exactly that (Bureau, #807). These two locals are how a screen reads the current theme; naming the
     * token object from `ui/` is refused by `OsraThemeTokensTest`.
     */
    val LocalOsraPalette = staticCompositionLocalOf { OsraTokens.light }
    val LocalOsraRadii = staticCompositionLocalOf { OsraTokens.lightRadii }

    /** The theme a screen wraps its content in. */
    @Composable
    fun OsraTheme(darkTheme: Boolean = androidx.compose.foundation.isSystemInDarkTheme(), content: @Composable () -> Unit) {
        val palette = if (darkTheme) OsraTokens.dark else OsraTokens.light
        val radii = if (darkTheme) OsraTokens.darkRadii else OsraTokens.lightRadii
        CompositionLocalProvider(
            LocalOsraPalette provides palette,
            LocalOsraRadii provides radii,
        ) {
            MaterialTheme(
                colorScheme = colors(palette, darkTheme),
                typography = typography(),
                shapes = shapes(radii),
                content = content,
            )
        }
    }

    /** The transparent colour the design file uses for "no outline"; exposed so a screen can compare. */
    val Transparent: Color = Color(0x00000000)
}
