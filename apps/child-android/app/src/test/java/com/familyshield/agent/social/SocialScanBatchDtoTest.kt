package com.familyshield.agent.social

import com.familyshield.agent.di.NetworkModule
import com.familyshield.agent.network.dto.SocialScanBatchDto
import com.familyshield.agent.network.dto.SocialScanDto
import org.junit.Assert.assertEquals
import org.junit.Test

class SocialScanBatchDtoTest {
    @Test
    fun `wire batch names the paired device at the root and in each item`() {
        val item = SocialScanDto(childId = "child-test", deviceId = "device-test", app = "whatsapp", text = "hello")
        val batch = SocialScanBatchDto(deviceId = item.deviceId, items = listOf(item))
        val adapter = NetworkModule.provideMoshi().adapter(SocialScanBatchDto::class.java)

        val json = adapter.toJsonValue(batch) as Map<*, *>
        val first = (json["items"] as List<*>).single() as Map<*, *>

        assertEquals(item.deviceId, json["deviceId"])
        assertEquals(item.deviceId, first["deviceId"])
        assertEquals(item.childId, first["childId"])
    }
}
