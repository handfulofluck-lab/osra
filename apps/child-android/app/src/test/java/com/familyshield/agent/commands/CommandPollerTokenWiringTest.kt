package com.familyshield.agent.commands

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** #383: the shared poll path reads X-Push-Token and the token step passes it into the upload rule. */
class CommandPollerTokenWiringTest {
    private val source = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandPoller.kt").readText()

    /** Mutant: pass `serverHasToken = null` (or drop the header) and the marker alone decides again. */
    @Test
    fun `pollOnce passes the header and the token step hands it to the upload rule`() {
        assertTrue(source.contains("syncPushToken(deviceId, response.headers()[PushTokenUploadPolicy.PUSH_TOKEN_HEADER])"))
        assertTrue(source.contains("PushTokenUploadPolicy.serverHasToken(pushTokenHeader)"))
        // A5 (Claude's review): computing the answer and then not passing it compiles, because the
        // parameter defaults to null — and the phone goes back to trusting its own marker. The line
        // above does not catch that; this one does.
        assertTrue(source.contains("shouldUpload(stored, settings.uploadedPushToken(), deviceId, serverHasToken)"))
    }

    /** Walks up from the Gradle working directory (the `app` module), as LocationServiceCadenceWiringTest does. */
    private fun sourceFile(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
