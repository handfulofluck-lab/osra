package com.familyshield.agent.enforcement

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #489 (Flip4, landscape): the block screen's title was clipped under the status bar and the cutout,
 * because at targetSdk 35 the screen is drawn edge to edge and neither overlay applied the window insets.
 * Each overlay's root column must add the safe-drawing insets before its own padding.
 */
class BlockScreenInsetsTest {

    private val rootModifier = "Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(32.dp)"

    @Test
    fun `the block screen's root column applies the safe-drawing insets`() {
        val text = source("enforcement/BlockActivity.kt")
        assertTrue("BlockScreen's root must pad by the insets", text.contains(rootModifier))
    }

    @Test
    fun `the lock screen's root column applies the safe-drawing insets`() {
        val text = source("commands/LockActivity.kt")
        assertTrue("OverlayScreen's root must pad by the insets", text.contains(rootModifier))
    }

    private fun source(path: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        var file: File? = null
        while (dir != null && file == null) {
            file = File(dir, "app/src/main/java/com/familyshield/agent/$path").takeIf { it.isFile }
            dir = dir.parentFile
        }
        return requireNotNull(file) { "source not found: $path" }.readText()
    }
}
