package com.familyshield.agent.manifest

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F1: what the rule files say, not just that the manifest names them. On Android 12+
 * `allowBackup="false"` does not stop device-to-device transfer, so `<device-transfer>` is what keeps the child's
 * pending chat text and location off a new phone.
 *
 * Mutant (Claude's): drop the device-transfer `sharedpref` exclude → [the extraction rules exclude every domain …].
 */
class BackupRulesTest {

    private val domains = listOf("root", "file", "database", "sharedpref", "external")

    @Test
    fun `the extraction rules exclude every domain from cloud backup and device transfer`() {
        val rules = sourceFile("app/src/main/res/xml/data_extraction_rules.xml")
        for (section in listOf("cloud-backup", "device-transfer")) {
            val body = rules.substringAfter("<$section>", missingDelimiterValue = "").substringBefore("</$section>", missingDelimiterValue = "")
            assertTrue("<$section> is present", body.isNotBlank())
            for (domain in domains) {
                assertTrue("<$section> excludes $domain", body.contains("<exclude domain=\"$domain\" path=\".\" />"))
            }
        }
    }

    @Test
    fun `the legacy backup rules exclude every domain`() {
        val legacy = sourceFile("app/src/main/res/xml/backup_rules.xml")
        for (domain in domains) {
            assertTrue("legacy rules exclude $domain", legacy.contains("<exclude domain=\"$domain\" path=\".\" />"))
        }
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
