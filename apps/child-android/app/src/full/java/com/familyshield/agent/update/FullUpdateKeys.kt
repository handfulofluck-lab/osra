package com.familyshield.agent.update

/**
 * ADR-0039 amendment row 3: the two Ed25519 manifest public keys compiled into the Full build. `m1` is the
 * primary and `m2` the offline backup made on the maintainer's PC; the private halves never leave that PC
 * (`docs/adr/0039-full-build-website-download.md`, D2 runbook), so there is nothing here to recover from a
 * compromised workflow.
 *
 * The values below are placeholders on purpose. `REPLACE_…` is not base64 of 32 bytes, so
 * [FullUpdatePolicy.publicKeyFromRawBase64] returns null, the key map is empty and every check refuses with
 * `manifest_key_unavailable` — a build with unpasted keys installs nothing rather than trusting anything.
 * The maintainer pastes the two raw-base64 values before the first Full release.
 */
object FullUpdateKeys {
    const val M1_BASE64: String = "REPLACE_WITH_M1_RAW_BASE64_FROM_THE_MAINTAINER"
    const val M2_BASE64: String = "REPLACE_WITH_M2_RAW_BASE64_FROM_THE_MAINTAINER"

    /** The `keyId` → raw base64 map [FullUpdater] hands to [FullUpdatePolicy] as untrusted input. */
    val byKeyId: Map<String, String> = mapOf(
        "m1" to M1_BASE64,
        "m2" to M2_BASE64,
    )
}
