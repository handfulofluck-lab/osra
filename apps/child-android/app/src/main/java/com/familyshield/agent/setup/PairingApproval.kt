package com.familyshield.agent.setup

import java.io.IOException
import java.net.URI

/**
 * The parent approves each new device (plan 2.7). A claimed code no longer returns a token: the claim
 * answers `202 { claimId, pollSecret }`, the parent taps Allow or Deny on the screen that is showing the
 * code, and this phone polls `POST /v1/devices/pair/claims/:claimId/poll` until the parent decides.
 *
 * Kept free of Android and JSON classes so a plain JVM test covers every answer the server can give;
 * [PairingActivity] does the HTTP and the JSON, and this decides what each status code means.
 */
object PairingApproval {

    /** One poll every two seconds: the server's poll bucket is 60 a minute per address. */
    const val POLL_INTERVAL_MS = 2_000L

    /** A code lives 600 s, so a claim cannot outlive it; this bounds the loop if the server never says. */
    const val MAX_POLLS = 330

    /** What the answer to `POST /v1/devices/pair/claim` means. */
    enum class ClaimStep { WAITING_FOR_PARENT, INVALID_CODE, ALREADY_CLAIMED, CONSENT_REQUIRED, FAILED }

    /** What one poll means. [APPROVED] is the only one that carries the device token (201). */
    enum class PollStep { PENDING, APPROVED, DENIED, EXPIRED, CONSENT_REQUIRED, FAILED, TIMED_OUT }

    fun claimStep(status: Int): ClaimStep = when (status) {
        202 -> ClaimStep.WAITING_FOR_PARENT
        404 -> ClaimStep.INVALID_CODE
        409 -> ClaimStep.ALREADY_CLAIMED
        428 -> ClaimStep.CONSENT_REQUIRED
        else -> ClaimStep.FAILED
    }

    fun pollStep(status: Int): PollStep = when (status) {
        202 -> PollStep.PENDING
        201 -> PollStep.APPROVED
        410 -> PollStep.DENIED
        // An unknown claim, an expired one and a wrong secret are the same answer on purpose.
        404 -> PollStep.EXPIRED
        428 -> PollStep.CONSENT_REQUIRED
        else -> PollStep.FAILED
    }

    /**
     * Polls until the parent decides or the claim ends. [poll] performs one request and returns its
     * status code; a network error ([IOException]) is a missed poll, not an answer, so the loop carries on.
     * Returns the first step that is not [PollStep.PENDING], or [PollStep.TIMED_OUT] after [maxPolls].
     */
    suspend fun awaitDecision(
        poll: suspend () -> Int,
        sleep: suspend (Long) -> Unit,
        maxPolls: Int = MAX_POLLS,
    ): PollStep {
        repeat(maxPolls) { attempt ->
            if (attempt > 0) sleep(POLL_INTERVAL_MS)
            val step = try {
                pollStep(poll())
            } catch (e: IOException) {
                PollStep.PENDING
            }
            if (step != PollStep.PENDING) return step
        }
        return PollStep.TIMED_OUT
    }

    /**
     * Release builds pair only with OSRA's own servers: an `https` URL on `osratech.com` or one of its
     * subdomains. A QR code is a picture anyone can print, so its server address is not trusted on a
     * build a family installs. Debug builds keep accepting any `http(s)` host for LAN and emulator testing.
     */
    fun isReleasePairingHost(url: String): Boolean {
        val uri = try {
            URI(url)
        } catch (e: Exception) {
            return false
        }
        val host = uri.host?.lowercase() ?: return false
        return uri.scheme.equals("https", ignoreCase = true) &&
            uri.userInfo == null &&
            (host == RELEASE_DOMAIN || host.endsWith(".$RELEASE_DOMAIN"))
    }

    const val RELEASE_DOMAIN = "osratech.com"
}
