package com.familyshield.agent.enforcement

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1094/#1095: the parent distinguishes an access request from an automatic blocked attempt by metadata,
 * not by inferring intent from the body. Mutants: omit `appName` from either alert, add `requestType` to
 * the automatic alert, change its request value, or drop an existing field pinned below.
 */
class BlockActivityAlertMetadataTest {

    private val activity = sourceFile("app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt")

    @Test
    fun `automatic blocked attempt names the app without becoming an access request`() {
        val alert = activity.substringAfter("private fun reportBlockedAttempt(")
            .substringBefore("private fun requestAccess(")
        val metadata = alert.metadata()

        assertTrue(alert.contains("category = \"app_blocked\""))
        assertTrue(alert.contains("body = \"Your child tried to open a blocked app.\""))
        assertTrue(metadata.contains("\"packageId\" to pkg"))
        assertTrue(metadata.contains("\"reason\" to reason"))
        assertTrue(metadata.contains("\"appName\" to appLabelSnapshot"))
        assertFalse("ordinary blocked attempts must remain non-actionable", alert.contains("requestType"))
    }

    @Test
    fun `access request names the app and carries the access request marker`() {
        val alert = activity.substringAfter("private fun requestAccess(")
            .substringBefore("companion object")
        val metadata = alert.metadata()

        assertTrue(alert.contains("category = \"app_blocked\""))
        assertTrue(alert.contains("body = \"Child requested access to \$pkg\""))
        assertTrue(metadata.contains("\"packageId\" to pkg"))
        assertTrue(metadata.contains("\"reason\" to reason"))
        assertTrue(metadata.contains("\"appName\" to appLabelSnapshot"))
        assertTrue(metadata.contains("\"requestType\" to \"access\""))
    }

    @Test
    fun `each producer snapshots the app label before launching IO work`() {
        val automatic = activity.substringAfter("private fun reportBlockedAttempt(")
            .substringBefore("private fun requestAccess(")
        val request = activity.substringAfter("private fun requestAccess(")
            .substringBefore("companion object")

        listOf(automatic, request).forEach { producer ->
            val snapshot = producer.indexOf("val appLabelSnapshot = appLabel")
            val launch = producer.indexOf("scope.launch")
            assertTrue("label snapshot must precede scope.launch", snapshot >= 0 && launch > snapshot)
            assertTrue(producer.contains("\"appName\" to appLabelSnapshot"))
            assertFalse("AlertDto must not read mutable appLabel inside Dispatchers.IO",
                producer.contains("\"appName\" to appLabel)") ||
                    producer.contains("\"appName\" to appLabel,"))
        }
    }

    private fun String.metadata(): String = substringAfter("metadata = mapOf(").substringBefore(")")

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
