package com.familyshield.agent.commands

import com.familyshield.agent.security.ParentPinStore.SetPrehashedResult

/**
 * #1108: `set_parent_pin`, a new OSRA PIN set from the parent app (Ahmed's R3 ruling on the issue, option A).
 *
 * The API checks the PIN against the shared rules and sends only its PBKDF2 hash, in the exact format this
 * app stores. Here the hash is handed to `ParentPinStore.setPrehashed`, which refuses any other shape and
 * keeps the old PIN when it does (condition 6). The ack tells the parent which way it went; the API clears
 * the hash from its row on that ack.
 *
 * The payload is never logged: it is as good as the PIN for an offline search.
 */
object ParentPinCommand {
    const val REASON_INVALID_PIN_HASH = "invalid_pin_hash"
    const val REASON_PIN_WRITE_FAILED = "pin_write_failed"

    fun apply(data: Map<String, String>, store: (String?) -> SetPrehashedResult): CommandOutcome =
        when (store(data["pinHash"])) {
            SetPrehashedResult.STORED -> CommandOutcome.Applied()
            SetPrehashedResult.INVALID_SHAPE -> CommandOutcome.Refused(REASON_INVALID_PIN_HASH)
            SetPrehashedResult.WRITE_FAILED -> CommandOutcome.Refused(REASON_PIN_WRITE_FAILED)
        }
}
