package com.familyshield.agent.setup

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F2 follow-up (Claude's correction): the fail-closed store must surface three ways — the next claim
 * flags `dataCleared` whatever the device-admin tier, the re-pair notice shows on the form, and a pairing whose secure
 * write could not persist fails visibly instead of starting the agent with a token that only lives in memory. The
 * tamper alert still rides the server-signed `dataCleared` claim, never an unsigned local POST (an unpaired phone's
 * `postInternalAlert` would answer 401).
 *
 * **Why source-text rows.** These decisions live inside an `Activity` and a Hilt `@Singleton` that a plain JVM test
 * cannot start (no Robolectric in this module); the pure halves are `SecureStoreOpener`, `SecureStoreWriter` and
 * `NoopSharedPreferences`, which their own suites test. This suite pins that the Android classes are wired to them.
 *
 * Mutants: drop `settings.secureStoreUnreadable()` from the detection → [the detection is the wipe signature]; drop
 * `put("dataCleared", true)` from the claim → [the claim flags the wipe]; make `savePairing` update caches before the
 * persistence check, or call `startAgent()` on a failed save → [a failed secure write starts nothing]; reuse the
 * cleared-data notice for a fresh secure-save failure → [the failure has its own bilingual recovery sentence]; add a
 * `TamperAlertWorker.enqueue` to [com.familyshield.agent.security.SecureStore] → [the fail-closed store raises no
 * unsigned alert].
 */
class DataClearedClaimWiringTest {

    private val pairing = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")
    private val secureStore = sourceFile("app/src/main/java/com/familyshield/agent/security/SecureStore.kt")
    private val agentSettings = sourceFile("app/src/main/java/com/familyshield/agent/data/AgentSettings.kt")

    @Test
    fun `the claim flags the wipe so the parent's Allow raises the tamper alert server-side`() {
        val claim = pairing.substringAfter("private suspend fun claim(").substringBefore("private fun userMessage")
        assertTrue(
            "the claim body must carry dataCleared when the wipe is detected; the server turns that into the " +
                "agent_data_cleared tamper alert on Allow",
            claim.contains("if (dataClearedDetected()) put(\"dataCleared\", true)"),
        )
    }

    @Test
    fun `the detection is the wipe signature plus the fail-closed store, so it fires whatever the admin tier`() {
        val detection = pairing.substringAfter("private fun dataClearedDetected(): Boolean =")
            .substringBefore("\n\n")
        assertTrue(
            "a fail-closed store must flag dataCleared on its own, independent of device-admin",
            detection.contains("settings.secureStoreUnreadable()"),
        )
        assertTrue(
            "the original pm-clear signature stays",
            detection.contains(
                "WipeDetector.dataCleared(deviceAdmin.isAdminActive(), paired = false, pinConfigured = pinStore.isConfigured())",
            ),
        )
    }

    @Test
    fun `the re-pair notice is the approved English string, shown from the same detection`() {
        assertTrue(
            "the cleared-data form keeps its original notice; a failed fresh save has its own reviewed line",
            pairing.contains("getString(R.string.wipe_detected_notice)"),
        )
        assertTrue(
            "the notice is gated by the same detection, so it shows without device-admin too",
            pairing.contains("if (dataClearedDetected())"),
        )
    }

    @Test
    fun `a failed secure write starts nothing and never caches a pairing`() {
        val onSuccess = pairing.substringAfter("result.onSuccess { pairing ->").substringBefore("}.onFailure")
        val saveIf = onSuccess.indexOf("if (settings.savePairing(")
        val start = onSuccess.indexOf("startAgent()")
        assertTrue("the claim result must be gated on the save", saveIf >= 0)
        assertTrue(
            "startAgent() must run only after a successful savePairing, so a no-op write never starts services",
            start > saveIf,
        )
        assertTrue(
            "a failed save has its own recovery notice rather than falsely claiming data was cleared",
            onSuccess.contains("getString(R.string.pairing_secure_store_failed)"),
        )
    }

    @Test
    fun `the secure-write failure notice has bilingual resources beside the wipe notice`() {
        listOf("values", "values-ar").forEach { folder ->
            val resources = sourceFile("app/src/main/res/$folder/strings.xml")
            val wipe = resources.indexOf("<string name=\"wipe_detected_notice\"")
            val secureSave = resources.indexOf("<string name=\"pairing_secure_store_failed\"")
            assertTrue("$folder must keep the original wipe notice", wipe >= 0)
            assertTrue("$folder must define the distinct secure-save notice", secureSave > wipe)
            assertFalse(
                "the Bureau asked for the new entry directly under wipe_detected_notice in $folder",
                resources.substring(wipe + 1, secureSave).contains("<string name="),
            )
        }
        val english = sourceFile("app/src/main/res/values/strings.xml")
        assertTrue(
            "the English is the reviewed recovery sentence",
            english.contains(
                "<string name=\"pairing_secure_store_failed\">OSRA could not save the pairing safely on this phone, " +
                    "so it is not protected yet. Restart the phone and pair it again. If this keeps happening, " +
                    "write to support@osratech.com.</string>",
            ),
        )
    }

    @Test
    fun `savePairing verifies persistence before any cache update`() {
        assertTrue("savePairing must retry a recovered store", agentSettings.contains("secure.reopenIfUnreadable()"))
        val savePairing = agentSettings.substringAfter("suspend fun savePairing(").substringBefore("\n    }\n")
        val guard = savePairing.indexOf("if (!secureWriter.writePairing(")
        val edit = savePairing.indexOf("store.edit {")
        val cache = savePairing.indexOf("tokenCache = deviceJwt")
        assertTrue("the persistence guard must exist", guard >= 0)
        assertTrue("the guard must precede store.edit (no DataStore write on a failed read-back)", guard < edit)
        assertTrue("the guard must precede tokenCache (no in-memory paired state on a failed read-back)", guard < cache)
    }

    @Test
    fun `legacy migration keeps the plaintext copy when the secure write fails closed`() {
        val readSecret = agentSettings.substringAfter("private suspend fun readSecret(").substringBefore("\n    }\n")
        val migrate = readSecret.indexOf("secureWriter.migrate(secureKey, legacy)")
        assertTrue("the migration goes through the verified writer", migrate >= 0)
        val earlyReturnAfterMigrate = readSecret.indexOf("?: return null", migrate)
        assertTrue("the verified migration must have its own early return", earlyReturnAfterMigrate >= 0)
        val remove = readSecret.indexOf("it.remove(plainKey)")
        assertTrue(
            "the plaintext copy is removed only after the migration's own early return, not the unrelated read() one",
            remove > earlyReturnAfterMigrate,
        )
    }

    @Test
    fun `the fail-closed store raises no unsigned alert`() {
        assertFalse(
            "SecureStore must not enqueue a TamperAlertWorker: after failing closed the phone is unpaired, so an " +
                "alert it posted would be unsigned and answer 401. The alert is the server-signed dataCleared one.",
            secureStore.contains("TamperAlertWorker"),
        )
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
