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
     * watch and the verdict call all have to be in the ring path. Mutant: drop comments and delete any one
     * of the real call sites (`holdFocus(app)` in `start()`, `AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)`,
     * `watchVolume(app)` in `start()`, `stream != AudioManager.STREAM_ALARM`, etc.) and this row fails while
     * every policy row above stays green.
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
        val startBody = code.substringAfter("fun start(").substringBefore("fun stop(")

        assertTrue("start() must acquire audio focus", startBody.contains("holdFocus(app)"))
        assertTrue(
            "the alarm must hold AUDIOFOCUS_GAIN, not transient",
            code.contains("AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)"),
        )
        assertTrue("start() must register the volume watch", startBody.contains("watchVolume(app)"))
        assertTrue(
            "the ring must listen for volume changes",
            code.contains("IntentFilter(\"android.media.VOLUME_CHANGED_ACTION\")"),
        )
        assertTrue("only the alarm stream is watched", code.contains("stream != AudioManager.STREAM_ALARM"))
        assertTrue("the decision is the pure policy's", code.contains("RingPolicy.volumeVerdict("))
        assertTrue("the attempt is counted for the report", code.contains("volumeRestorations += 1"))
        assertTrue("focus is released on stop", code.contains("abandonAudioFocusRequest"))
        assertTrue("the watch is unregistered on stop", code.contains("unregisterReceiver"))
    }
}
