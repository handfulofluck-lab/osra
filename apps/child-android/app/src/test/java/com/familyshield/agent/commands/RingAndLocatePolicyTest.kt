package com.familyshield.agent.commands

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Plan 1.7: who may stop a ring, and which fix a locate_now reports. */
class RingAndLocatePolicyTest {

    @Test
    fun `only the parent's PIN, a parent command or the cap stop a ring`() {
        assertTrue(RingPolicy.stopAllowed(RingPolicy.StopSource.PIN_VERIFIED))
        assertTrue(RingPolicy.stopAllowed(RingPolicy.StopSource.PARENT_COMMAND))
        assertTrue(RingPolicy.stopAllowed(RingPolicy.StopSource.TIMEOUT))
        assertFalse(RingPolicy.stopAllowed(RingPolicy.StopSource.CHILD_BACK))
        assertFalse(RingPolicy.stopAllowed(RingPolicy.StopSource.CHILD_VOLUME_KEY))
        assertFalse(RingPolicy.stopAllowed(RingPolicy.StopSource.SCREEN_OFF))
    }

    @Test
    fun `ring runs at the stream maximum and the cap is five minutes`() {
        assertEquals(15, RingPolicy.ringVolume(15))
        assertEquals(1, RingPolicy.ringVolume(0))
        assertEquals(5 * 60 * 1000L, RingPolicy.MAX_RING_MS)
    }

    @Test
    fun `volume is restored only when nobody touched it during the ring`() {
        assertEquals(3, RingPolicy.restoreVolume(previous = 3, current = 15, ringLevel = 15))
        assertEquals(7, RingPolicy.restoreVolume(previous = 3, current = 7, ringLevel = 15))
    }

    @Test
    fun `locate prefers a fresh fix, falls back to a recent cached one, reports nothing for a stale one`() {
        val now = 1_000_000L
        assertEquals(LocatePolicy.Choice.FRESH, LocatePolicy.choose(freshAvailable = true, cachedTimeMs = now - 60_000, nowMs = now))
        assertEquals(LocatePolicy.Choice.CACHED, LocatePolicy.choose(freshAvailable = false, cachedTimeMs = now - 60_000, nowMs = now))
        assertEquals(LocatePolicy.Choice.NONE, LocatePolicy.choose(freshAvailable = false, cachedTimeMs = now - 6 * 60_000, nowMs = now))
        assertEquals(LocatePolicy.Choice.NONE, LocatePolicy.choose(freshAvailable = false, cachedTimeMs = null, nowMs = now))
        assertEquals(30_000L, LocatePolicy.FRESH_FIX_TIMEOUT_MS)
    }

    /**
     * osra-security#42 (Ahmed): a child must not be able to silence a ring with the volume keys while it
     * stays active. The guard is downward-only and has no opinion when there is no floor to defend.
     */
    @Test
    fun `a volume drop below the floor is put back, anything else is left alone`() {
        assertEquals(RingPolicy.VolumeVerdict.RESTORE, RingPolicy.volumeVerdict(current = 4, floor = 15))
        assertEquals(RingPolicy.VolumeVerdict.RESTORE, RingPolicy.volumeVerdict(current = 0, floor = 1))
        assertEquals(RingPolicy.VolumeVerdict.IGNORE, RingPolicy.volumeVerdict(current = 15, floor = 15))
        assertEquals(RingPolicy.VolumeVerdict.IGNORE, RingPolicy.volumeVerdict(current = 14, floor = 0))
        assertEquals(RingPolicy.VolumeVerdict.IGNORE, RingPolicy.volumeVerdict(current = 15, floor = -1))
    }

    /**
     * The wiring the device row would otherwise be the only evidence for: the focus hold, the alarm-stream
     * watch, the verdict call, and the stop cleanup all have to live inside their real functions. Mutants
     * killed (`M3a`..`M3c`, `M4`..`M7`): replace `AUDIOFOCUS_GAIN` (`M3a`/`M3b`), drop `holdFocus(app)` in
     * `start()` (`M3c`), drop `audio.requestAudioFocus(...)` in `holdFocus()` (`M4`), drop
     * `ContextCompat.registerReceiver(...)` in `watchVolume()` (`M5`), or drop `releaseFocus(app)` (`M6`) /
     * `stopWatchingVolume()` (`M7`) in `stopLocked()`. Each fails this row while every policy row stays green.
     */
    @Test
    fun `the ring holds audio focus and watches the alarm stream while it plays`() {
        val source = File(
            "src/main/java/com/familyshield/agent/commands/Ringer.kt",
        ).takeIf { it.isFile }?.readText() ?: run {
            var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
            var found: File? = null
            while (dir != null && found == null) {
                val candidate = File(dir, "apps/child-android/app/src/main/java/com/familyshield/agent/commands/Ringer.kt")
                if (candidate.isFile) found = candidate
                dir = dir.parentFile
            }
            found?.readText() ?: error("Ringer.kt not found")
        }

        val code = source.replace(Regex("/\\*[\\s\\S]*?\\*/|//.*"), "")

        fun bodyOf(signature: String): String {
            val start = code.indexOf(signature)
            require(start >= 0) { "Function $signature not found in Ringer.kt" }
            val openBrace = code.indexOf('{', start)
            require(openBrace >= 0) { "Opening brace for $signature not found" }
            var depth = 0
            var inString = false
            var escaped = false
            for (i in openBrace until code.length) {
                val ch = code[i]
                if (inString) {
                    if (escaped) {
                        escaped = false
                    } else if (ch == '\\') {
                        escaped = true
                    } else if (ch == '"') {
                        inString = false
                    }
                    continue
                }
                when (ch) {
                    '"' -> inString = true
                    '{' -> depth += 1
                    '}' -> {
                        depth -= 1
                        if (depth == 0) return code.substring(openBrace + 1, i)
                    }
                }
            }
            error("Unclosed brace for $signature")
        }

        val startBody = bodyOf("fun start(")
        val stopLockedBody = bodyOf("fun stopLocked(")
        val holdFocusBody = bodyOf("fun holdFocus(")
        val releaseFocusBody = bodyOf("fun releaseFocus(")
        val watchVolumeBody = bodyOf("fun watchVolume(")
        val stopWatchingBody = bodyOf("fun stopWatchingVolume(")

        assertTrue("start() must acquire audio focus", startBody.contains("holdFocus(app)"))
        assertTrue("start() must register the volume watch", startBody.contains("watchVolume(app)"))
        assertTrue(
            "the alarm must hold AUDIOFOCUS_GAIN, not transient",
            holdFocusBody.contains("AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)"),
        )
        assertTrue("holdFocus() must actually request audio focus", holdFocusBody.contains("requestAudioFocus("))
        assertTrue(
            "the ring must listen for volume changes",
            watchVolumeBody.contains("IntentFilter(\"android.media.VOLUME_CHANGED_ACTION\")"),
        )
        assertTrue("watchVolume() must register the BroadcastReceiver", watchVolumeBody.contains("registerReceiver("))
        assertTrue("only the alarm stream is watched", watchVolumeBody.contains("stream != AudioManager.STREAM_ALARM"))
        assertTrue("the decision is the pure policy's", watchVolumeBody.contains("RingPolicy.volumeVerdict("))
        assertTrue("the attempt is counted for the report", watchVolumeBody.contains("volumeRestorations += 1"))
        assertTrue("stopLocked() must release audio focus", stopLockedBody.contains("releaseFocus(app)"))
        assertTrue("stopLocked() must unregister the volume watch", stopLockedBody.contains("stopWatchingVolume()"))
        assertTrue("releaseFocus() must abandon the focus request", releaseFocusBody.contains("abandonAudioFocusRequest"))
        assertTrue("stopWatchingVolume() must unregister the receiver", stopWatchingBody.contains("unregisterReceiver"))
        assertTrue(
            "stopLocked() only reports ring_volume when volumeRestorations > 0",
            stopLockedBody.contains("RingPolicy.shouldReportVolumeAttempts(") &&
                stopLockedBody.contains("reportVolumeAttempts("),
        )
        val reportBody = bodyOf("fun reportVolumeAttempts(")
        assertTrue("reportVolumeAttempts() sets category ring_volume", reportBody.contains("category = \"ring_volume\""))
        assertTrue("reportVolumeAttempts() sets severity info (Alerts list only)", reportBody.contains("severity = \"info\""))
        assertTrue("reportVolumeAttempts() posts via postInternalAlert", reportBody.contains("postInternalAlert("))
    }

    @Test
    fun `ring_volume alert policy fires once per ring only when volume was restored`() {
        assertFalse(RingPolicy.shouldReportVolumeAttempts(0))
        assertTrue(RingPolicy.shouldReportVolumeAttempts(1))
        assertTrue(RingPolicy.shouldReportVolumeAttempts(5))

        assertEquals(
            "Tried to turn down the ring volume once. The phone kept ringing.",
            RingPolicy.ringVolumeAlertBody(1),
        )
        assertEquals(
            "Tried to turn down the ring volume 5 times. The phone kept ringing.",
            RingPolicy.ringVolumeAlertBody(5),
        )
        assertEquals("dev-1|ring_volume|101", RingPolicy.ringVolumeDedupeKey("dev-1", 101L))
        assertEquals("dev-1|ring_volume|102", RingPolicy.ringVolumeDedupeKey("dev-1", 102L))
    }
}
