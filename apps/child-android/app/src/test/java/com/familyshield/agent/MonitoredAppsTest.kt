package com.familyshield.agent

import com.familyshield.agent.social.MonitoredApps
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Pure-JVM tests for the monitored social-app package mapping (Features #2/#17). */
class MonitoredAppsTest {

    @Test
    fun `whatsapp and whatsapp business map to whatsapp`() {
        assertEquals("whatsapp", MonitoredApps.appKeyFor("com.whatsapp"))
        assertEquals("whatsapp", MonitoredApps.appKeyFor("com.whatsapp.w4b"))
    }

    @Test
    fun `gaming chat apps map to their keys`() {
        assertEquals("discord", MonitoredApps.appKeyFor("com.discord"))
        assertEquals("roblox", MonitoredApps.appKeyFor("com.roblox.client"))
    }

    @Test
    fun `social apps map to their keys`() {
        assertEquals("instagram", MonitoredApps.appKeyFor("com.instagram.android"))
        assertEquals("tiktok", MonitoredApps.appKeyFor("com.zhiliaoapp.musically"))
        assertEquals("tiktok", MonitoredApps.appKeyFor("com.ss.android.ugc.trill"))
        assertEquals("snapchat", MonitoredApps.appKeyFor("com.snapchat.android"))
        assertEquals("twitter", MonitoredApps.appKeyFor("com.twitter.android"))
        assertEquals("twitter", MonitoredApps.appKeyFor("com.x.android"))
        assertEquals("line", MonitoredApps.appKeyFor("jp.naver.line.android"))
    }

    @Test
    fun `unmonitored packages return null`() {
        assertNull(MonitoredApps.appKeyFor("com.android.settings"))
        assertNull(MonitoredApps.appKeyFor("com.familyshield.agent"))
        assertNull(MonitoredApps.appKeyFor("com.whatsapp2")) // not a prefix match
    }
}
