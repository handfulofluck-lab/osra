package com.familyshield.agent.setup

/**
 * #440 Flip4 follow-up: with `targetSdk 35`, Android 15 draws every activity edge to edge, so the pairing
 * form's and the PIN step's title sat under the status bar, over the clock. The root keeps its own padding
 * and adds whatever the system bars, the display cutout and the keyboard take on each side.
 */
object SystemBarPadding {
    data class Padding(val left: Int, val top: Int, val right: Int, val bottom: Int)

    fun of(basePx: Int, left: Int, top: Int, right: Int, bottom: Int): Padding =
        Padding(basePx + left, basePx + top, basePx + right, basePx + bottom)
}
