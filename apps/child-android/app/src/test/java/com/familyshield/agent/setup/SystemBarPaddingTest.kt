package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** #440 Flip4 follow-up: the pairing title drew under the status bar at targetSdk 35 (edge to edge). */
class SystemBarPaddingTest {

    @Test
    fun `the status bar, cutout and keyboard are added to the root's own padding`() {
        assertEquals(
            SystemBarPadding.Padding(left = 40, top = 40 + 96, right = 40, bottom = 40 + 0),
            SystemBarPadding.of(basePx = 40, left = 0, top = 96, right = 0, bottom = 0),
        )
        assertEquals("a landscape cutout pads its side", 40 + 120, SystemBarPadding.of(40, 120, 0, 0, 0).left)
    }

    @Test
    fun `the pairing activity applies the insets to its root`() {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        var source: File? = null
        while (dir != null && source == null) {
            source = File(dir, "app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt").takeIf { it.isFile }
            dir = dir.parentFile
        }
        val text = requireNotNull(source).readText()
        assertTrue(text.contains("setOnApplyWindowInsetsListener"))
        assertTrue(text.contains("SystemBarPadding.of(pad"))
    }
}
