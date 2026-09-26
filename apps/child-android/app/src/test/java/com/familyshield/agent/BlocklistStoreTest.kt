package com.familyshield.agent

import com.familyshield.agent.data.BlocklistStore
import com.familyshield.agent.network.dto.BlocklistCategoryDto
import com.familyshield.agent.network.dto.BlocklistPackDto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the default-category blocklist merge helper (Feature #1). */
class BlocklistStoreTest {

    private fun packJson(): String = """
        {
          "version": 3,
          "updatedAt": "2026-09-01T00:00:00Z",
          "categories": [
            {
              "category": "gambling",
              "domains": ["bet.example"],
              "appsAndroid": ["com.example.bet", "com.example.casino"],
              "appsWindows": ["bet.exe"]
            },
            {
              "category": "dating",
              "domains": ["date.example"],
              "appsAndroid": ["com.example.dating"],
              "appsWindows": []
            },
            {
              "category": "pornography",
              "domains": ["adult.example"],
              "appsAndroid": ["com.example.bet", "com.example.adult"],
              "appsWindows": []
            }
          ]
        }
    """.trimIndent()

    @Test
    fun `merge maps android apps to their category filtered by blocked categories`() {
        val merged = BlocklistStore.merge(packJson(), listOf("gambling", "pornography"))
        assertEquals(
            mapOf(
                "com.example.bet" to "gambling", // first blocked category wins (pack order)
                "com.example.casino" to "gambling",
                "com.example.adult" to "pornography",
            ),
            merged,
        )
    }

    @Test
    fun `merge excludes apps whose category is not blocked`() {
        val merged = BlocklistStore.merge(packJson(), listOf("gambling"))
        assertTrue("com.example.dating" !in merged)
        assertTrue("com.example.adult" !in merged)
        assertEquals("gambling", merged["com.example.casino"])
    }

    @Test
    fun `merge matches categories and packages case-insensitively`() {
        val merged = BlocklistStore.merge(packJson(), listOf("Gambling", " PORNOGRAPHY "))
        assertEquals(setOf("com.example.bet", "com.example.casino", "com.example.adult"), merged.keys)
        val mixedCase = """
            {"version":1,"updatedAt":"","categories":[
              {"category":"Gambling","domains":[],"appsAndroid":["Com.Example.BET"],"appsWindows":[]}
            ]}
        """.trimIndent()
        val m2 = BlocklistStore.merge(mixedCase, listOf("gambling"))
        assertEquals("gambling", m2["com.example.bet"])
        assertTrue("Com.Example.BET" !in m2)
    }

    @Test
    fun `merge dedupes a package across categories keeping the first`() {
        val merged = BlocklistStore.merge(packJson(), listOf("gambling", "pornography"))
        assertEquals("gambling", merged["com.example.bet"])
        assertEquals(3, merged.size)
    }

    @Test
    fun `merge returns empty map for empty pack`() {
        assertTrue(BlocklistStore.merge("", listOf("gambling")).isEmpty())
        assertTrue(
            BlocklistStore.merge("{\"version\":0,\"updatedAt\":\"\",\"categories\":[]}", listOf("gambling")).isEmpty(),
        )
    }

    @Test
    fun `merge returns empty map for malformed json`() {
        assertTrue(BlocklistStore.merge("not json", listOf("gambling")).isEmpty())
    }

    @Test
    fun `merge returns empty map when no category is blocked`() {
        assertTrue(BlocklistStore.merge(packJson(), emptyList()).isEmpty())
    }

    @Test
    fun `merge ignores windows-only apps and parsed form matches json form`() {
        val pack = BlocklistPackDto(
            version = 3,
            updatedAt = "2026-09-01T00:00:00Z",
            categories = listOf(
                BlocklistCategoryDto(category = "gambling", appsAndroid = listOf("com.example.bet")),
            ),
        )
        val fromJson = BlocklistStore.merge(packJson(), listOf("gambling"))
        val fromObj = BlocklistStore.merge(pack, listOf("gambling"))
        assertEquals(fromJson["com.example.bet"], fromObj["com.example.bet"])
        assertNull(fromObj["bet.exe"])
    }
}
