package com.familyshield.agent.setup

/** What the pairing screen would post once a person confirms. */
data class PairingRequest(
    val serverUrl: String,
    val code: String,
    val deviceName: String,
)

/**
 * The scan → review → confirm state machine, kept free of Android classes so a JVM test can prove the
 * property the UX depends on: **scanning alone never builds a pairing request**. [confirm] is the only
 * method that returns a [PairingRequest], and it returns `null` unless a valid payload is under review.
 *
 * The confirm step is therefore reachable without a camera — it is plain state, not a camera callback —
 * and the typed form keeps its own path next to it.
 */
class PairingScanFlow {

    sealed interface State {
        data object Idle : State
        data class Review(val payload: PairQrPayload) : State
        data class Rejected(val reason: String) : State
    }

    var state: State = State.Idle
        private set

    /** Decodes [raw] and moves to [State.Review] or [State.Rejected]; never returns a request. */
    fun scan(raw: String): State {
        state = try {
            State.Review(PairQrPayload.decode(raw))
        } catch (e: PairQrFormatException) {
            State.Rejected(e.message ?: "not an OSRA pairing code")
        }
        return state
    }

    /**
     * The explicit confirmation. Returns null when there is nothing to confirm (no scan, or the last
     * scan was rejected), so a caller cannot accidentally pair from an untouched screen.
     */
    fun confirm(deviceName: String): PairingRequest? {
        val review = state as? State.Review ?: return null
        return PairingRequest(
            serverUrl = review.payload.apiBaseUrl,
            code = review.payload.code,
            deviceName = deviceName.trim(),
        )
    }

    fun cancel() {
        state = State.Idle
    }
}
