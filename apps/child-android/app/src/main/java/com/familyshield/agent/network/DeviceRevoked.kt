package com.familyshield.agent.network

/**
 * Issue #465: the one place that decides a response means "this phone is no longer linked".
 *
 * When a parent deletes the family (#464), the server deletes the child's device rows, so the agent's
 * next call answers `401 {"error":"device_revoked"}` (#56). Before this, `CommandPoller` threw on any
 * non-2xx and simply retried, so a deleted family's phone kept enforcing its last rules and kept its
 * device-admin grant forever — no parent could unpair it, because the account that would have done so
 * was gone, and the child cannot uninstall a device admin.
 *
 * **Why this is a separate, pure function.** Three look-alikes must never unlink a phone: a network
 * failure, a 5xx, and a plain `401` that a token refresh can fix. Unlinking on any of them would wipe a
 * child's protection for a transient reason. So the decision reads exactly two things — the status code
 * and the body's `error` code — and U2 pins all three negatives.
 */
object DeviceRevoked {

    /** The body code the server sends for a device whose row is gone (`services/api/src/middleware/sessionGuard.ts`). */
    const val CODE: String = "device_revoked"

    /**
     * True only for `401` with `error = "device_revoked"`.
     *
     * [errorCode] is the parsed body's `error` field, or null when the body is absent or unparseable; a
     * missing code is never treated as a revocation, because "I could not read the answer" is not an
     * answer.
     */
    fun isRevoked(status: Int, errorCode: String?): Boolean = status == 401 && errorCode == CODE

    /**
     * The `error` code in a JSON body, or null when there is none.
     *
     * A regex over the raw body rather than a parser: this decision sits on the poll path and must not
     * throw on a malformed or truncated error body, and the one field it needs has no nesting.
     */
    fun codeFromBody(body: String?): String? {
        if (body.isNullOrBlank()) return null
        return ERROR_FIELD.find(body)?.groupValues?.getOrNull(1)
    }

    private val ERROR_FIELD = Regex("\"error\"\\s*:\\s*\"([^\"]*)\"")
}
