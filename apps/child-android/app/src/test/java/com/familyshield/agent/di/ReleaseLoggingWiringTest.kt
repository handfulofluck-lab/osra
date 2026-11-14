package com.familyshield.agent.di

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F4: the HTTP logging interceptor writes every request line, child and device ids included, to
 * logcat. A release build must not attach it. Source row: the one place it is attached is under
 * `BuildConfig.DEBUG`, and nothing else in the app attaches one.
 */
class ReleaseLoggingWiringTest {

    @Test
    fun `the logging interceptor is attached only in debug builds`() {
        val module = sourceFile("app/src/main/java/com/familyshield/agent/di/NetworkModule.kt")
        val uses = module.lines().filter { it.contains("HttpLoggingInterceptor()") }
        assertEquals("one place attaches it", 1, uses.size)
        assertTrue("only when BuildConfig.DEBUG", uses.single().contains("if (BuildConfig.DEBUG) addInterceptor(HttpLoggingInterceptor()"))
        val others = File(root(), "app/src/main/java").walk()
            .filter { it.isFile && it.extension == "kt" && it.name != "NetworkModule.kt" }
            .filter { it.readText().contains("HttpLoggingInterceptor") }
            .map { it.name }.toList()
        assertEquals("no other file uses it", emptyList<String>(), others)
    }

    private fun root(): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            if (File(dir, "app/src/main/java").isDirectory) return dir
            dir = dir.parentFile
        }
        throw AssertionError("could not find app/src/main/java from ${System.getProperty("user.dir")}")
    }

    private fun sourceFile(relative: String): String = File(root(), relative).readText()
}
