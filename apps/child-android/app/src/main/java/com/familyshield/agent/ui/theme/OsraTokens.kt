// GENERATED FILE — do not edit by hand.
// Source: docs/design/tokens.json (version 1).
// Generator: scripts/gen-android-tokens.mjs. Written for #728, so every screen after it (lock, block, SOS,
// ring, the PIN gate) has one theme rather than a colour chosen per screen.
//
// This file is checked, not trusted: scripts/gen-android-tokens.mjs --check fails when it no longer matches
// the design file, and workflow-lint runs that check — so a token change that does not reach Android is a red
// CI job, not a wrong colour on a phone.
package com.familyshield.agent.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object OsraTokens {

    /** One colour per name, in the two themes the design file defines. */
    data class Palette(
        val page: Color,
        val card: Color,
        val cardBorder: Color,
        val raised: Color,
        val line: Color,
        val border: Color,
        val inputBorder: Color,
        val ink: Color,
        val muted: Color,
        val primary: Color,
        val onPrimary: Color,
        val tint: Color,
        val ok: Color,
        val warn: Color,
        val warnContainer: Color,
        val onWarnContainer: Color,
        val warnSolid: Color,
        val onWarnSolid: Color,
        val danger: Color,
        val onDanger: Color,
        val track: Color,
        val switchOff: Color,
        val switchKnob: Color,
        val barIdle: Color,
        val bandBedtime: Color,
        val bandSchool: Color,
        val bandInk: Color,
        val scrim: Color,
        val mapGround: Color,
    )

    /** Corner radii. They differ per theme on purpose: dark surfaces read larger, so the design shrinks them. */
    data class Radii(val card: Dp, val control: Dp, val sheet: Dp, val bar: Dp)

    /** Spacing steps. */
    data class Spaces(val xxs: Dp, val xs: Dp, val sm: Dp, val md: Dp, val lg: Dp, val xl: Dp, val xxl: Dp)

    /** Fixed sizes the screens share. */
    data class Sizes(val touchTargetMin: Dp, val primaryButtonHeight: Dp, val actionButtonHeight: Dp, val bottomBarHeight: Dp, val avatar: Dp)

    /** One step of the type scale: size, line height and weight, as the design file states them. */
    data class TypeStyle(val sizeSp: Int, val lineSp: Int, val weight: Int)

    /**
     * The palette, light. The names and their use:
     * - page: Screen background
     * - card: Cards, lists, sheets, bottom bar
     * - cardBorder: 1 px card outline (dark only)
     * - raised: Secondary buttons, steppers
     * - line: Dividers inside a card
     * - border: Outline of secondary buttons and cards
     * - inputBorder: Enabled text-field outline (>= 3:1 WCAG 1.4.11 non-text contrast)
     * - ink: Primary text
     * - muted: Secondary text
     * - primary: Primary button, switch on, links, today's bar
     * - onPrimary: Text on primary
     * - tint: Selected row, app icon tile
     * - ok: 'Protected', 'Active on the phone'
     * - warn: 'Needs attention' text, limit line on charts
     * - warnContainer: Needs-attention box
     * - onWarnContainer: Text in the needs-attention box
     * - warnSolid: Fix button
     * - onWarnSolid: Text on the Fix button
     * - danger: Safety concern, destructive action
     * - onDanger: Text on danger
     * - track: Progress track, day strip background
     * - switchOff: Switch track when off
     * - switchKnob: Switch knob
     * - barIdle: Chart bars that are not today or not selected
     * - bandBedtime: Bedtime band on the day strip
     * - bandSchool: School time and other schedule bands
     * - bandInk: Label inside a band
     * - scrim: Behind a sheet
     * - mapGround: Map placeholder ground (real map tiles follow the theme)
     */
    val light = Palette(
        page = Color(0xFFF1F5F4),
        card = Color(0xFFFFFFFF),
        cardBorder = Color(0x00000000),
        raised = Color(0xFFFFFFFF),
        line = Color(0xFFE6ECEB),
        border = Color(0xFFC9D6D3),
        inputBorder = Color(0xFF6E7E7B),
        ink = Color(0xFF12211F),
        muted = Color(0xFF4D5E5A),
        primary = Color(0xFF0B5D57),
        onPrimary = Color(0xFFFFFFFF),
        tint = Color(0xFFEAF2F0),
        ok = Color(0xFF0B5D57),
        warn = Color(0xFF8A4B00),
        warnContainer = Color(0xFFFFF0D4),
        onWarnContainer = Color(0xFF5E3300),
        warnSolid = Color(0xFF8A4B00),
        onWarnSolid = Color(0xFFFFFFFF),
        danger = Color(0xFFA3242B),
        onDanger = Color(0xFFFFFFFF),
        track = Color(0xFFE2EAE8),
        switchOff = Color(0xFF7D8C89),
        switchKnob = Color(0xFFFFFFFF),
        barIdle = Color(0xFF7F9792),
        bandBedtime = Color(0xFFC7D0E2),
        bandSchool = Color(0xFFDCE4CC),
        bandInk = Color(0xFF2C3A37),
        scrim = Color(0xFF5D6866),
        mapGround = Color(0xFFDDE7E4),
    )

    /** The palette, dark. Same names, the design file's dark column. */
    val dark = Palette(
        page = Color(0xFF0E1417),
        card = Color(0xFF172026),
        cardBorder = Color(0xFF2B3840),
        raised = Color(0xFF1E2A31),
        line = Color(0xFF2B3840),
        border = Color(0xFF3A4A53),
        inputBorder = Color(0xFF6A7C86),
        ink = Color(0xFFE9EFF1),
        muted = Color(0xFFA7B6BD),
        primary = Color(0xFF7DB4FF),
        onPrimary = Color(0xFF0E1417),
        tint = Color(0xFF1E2A31),
        ok = Color(0xFF86D4BE),
        warn = Color(0xFFFFB454),
        warnContainer = Color(0xFF3A2A10),
        onWarnContainer = Color(0xFFFFD9A0),
        warnSolid = Color(0xFFFFB454),
        onWarnSolid = Color(0xFF0E1417),
        danger = Color(0xFFFF9A8C),
        onDanger = Color(0xFF0E1417),
        track = Color(0xFF2B3840),
        switchOff = Color(0xFF6A7C86),
        switchKnob = Color(0xFF0E1417),
        barIdle = Color(0xFF5C7483),
        bandBedtime = Color(0xFF2A3550),
        bandSchool = Color(0xFF2F3B33),
        bandInk = Color(0xFFC9D4D9),
        scrim = Color(0xFF05080A),
        mapGround = Color(0xFF121B20),
    )

    val lightRadii = Radii(card = 18.dp, control = 12.dp, sheet = 26.dp, bar = 4.dp)
    val darkRadii = Radii(card = 12.dp, control = 8.dp, sheet = 16.dp, bar = 4.dp)

    val spaces = Spaces(xxs = 2.dp, xs = 4.dp, sm = 8.dp, md = 12.dp, lg = 16.dp, xl = 24.dp, xxl = 32.dp)

    val sizes = Sizes(touchTargetMin = 44.dp, primaryButtonHeight = 52.dp, actionButtonHeight = 44.dp, bottomBarHeight = 64.dp, avatar = 40.dp)

    /** 26/32, weight 700. */
    val screenTitle = TypeStyle(sizeSp = 26, lineSp = 32, weight = 700)

    /** 22/28, weight 700. */
    val pageTitle = TypeStyle(sizeSp = 22, lineSp = 28, weight = 700)

    /** 17/23, weight 400. */
    val status = TypeStyle(sizeSp = 17, lineSp = 23, weight = 400)

    /** 17/22, weight 700. */
    val cardTitle = TypeStyle(sizeSp = 17, lineSp = 22, weight = 700)

    /** 15/20, weight 400. */
    val body = TypeStyle(sizeSp = 15, lineSp = 20, weight = 400)

    /** 15/20, weight 600. */
    val rowTitle = TypeStyle(sizeSp = 15, lineSp = 20, weight = 600)

    /** 13/18, weight 400. */
    val secondary = TypeStyle(sizeSp = 13, lineSp = 18, weight = 400)

    /** 11/14, weight 400. */
    val caption = TypeStyle(sizeSp = 11, lineSp = 14, weight = 400)

    /** 48/52, weight 700. */
    val bigNumber = TypeStyle(sizeSp = 48, lineSp = 52, weight = 700)

    /** The two families; every step above is drawn in one of them (no system font, no system blue). */
    const val FONT_LATIN = "IBM Plex Sans"
    const val FONT_ARABIC = "IBM Plex Sans Arabic"
}
