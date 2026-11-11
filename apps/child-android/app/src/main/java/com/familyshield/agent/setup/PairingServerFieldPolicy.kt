package com.familyshield.agent.setup

/**
 * Issue G4 of the customer guide (`docs/customer/GUIDE-GAPS.md`): **a release build must not ask a child to type
 * a server address the parent's screen never shows.**
 *
 * Three sources compete for the field, and only one of them is a person typing into it:
 *
 * 1. **A scanned QR code** carries the server, the code and the name. It wins outright and locks the field —
 *    that is what the parent's screen produces, and nothing about it should be editable afterwards.
 * 2. **The build's own server** ([builtIn], from `BuildConfig.API_BASE`, set when the artefact is made for a
 *    known deployment). It prefills and locks the field for the same reason: there is exactly one right answer,
 *    and a typo turns "pair this phone" into a support call.
 * 3. **The tester's own address**, today's behaviour for a debug build against a LAN server. Editable, because
 *    nobody knows the right address until someone types it.
 *
 * The order matters: a QR beats the build's server, so a phone provisioned for staging can still be pointed at
 * production by scanning, and the reverse. What never happens is a locked field with an empty value.
 *
 * Pure and Android-free, so the rule is a JVM row; [com.familyshield.agent.setup.PairingActivity] is the adapter.
 */
object PairingServerFieldPolicy {

    /** What the server field should contain, and whether the child may change it. */
    data class Field(
        val value: String,
        /** False when the value is known to be the only right one (a scan, or the build's own server). */
        val editable: Boolean,
        /** True when the value came from a scanned QR — the form then also shows the masked code. */
        val fromQr: Boolean,
        /** True when the value came from the build rather than from a person or a scan. */
        val fromBuild: Boolean,
    )

    /**
     * The field for one render.
     *
     * @param scannedUrl the server from a scanned QR, or null when nothing was scanned
     * @param builtInUrl `BuildConfig.API_BASE` — blank in a test or sideloaded build unless it was set
     * @param typed whatever is currently in the field, kept so a failed scan does not wipe a typist's work
     */
    fun field(scannedUrl: String?, builtInUrl: String?, typed: String): Field {
        val scanned = scannedUrl?.trim().orEmpty()
        if (scanned.isNotEmpty()) {
            return Field(value = scanned, editable = false, fromQr = true, fromBuild = false)
        }
        val builtIn = builtInUrl?.trim().orEmpty()
        if (builtIn.isNotEmpty()) {
            return Field(value = builtIn, editable = false, fromQr = false, fromBuild = true)
        }
        return Field(value = typed, editable = true, fromQr = false, fromBuild = false)
    }

    /**
     * The code field follows the server field: a QR carries both, so both lock; a built-in server carries no
     * code, so the six digits stay the one thing a person must read out of the parent's screen.
     */
    fun codeEditable(field: Field): Boolean = !field.fromQr
}
