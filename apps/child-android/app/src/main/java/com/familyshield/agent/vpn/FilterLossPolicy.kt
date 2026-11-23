package com.familyshield.agent.vpn

/** A filter loss belongs to one period of active consent. */
internal object FilterLossPolicy {
    fun isLost(
        recordedEpoch: Long?,
        enabled: Boolean,
        paired: Boolean,
        consentPaused: Boolean,
        consentEpoch: Long,
    ): Boolean = expected(enabled, paired, consentPaused) && recordedEpoch == consentEpoch

    fun shouldRecord(
        recordedEpoch: Long?,
        wasEstablished: Boolean,
        enabled: Boolean,
        paired: Boolean,
        consentPaused: Boolean,
        consentEpoch: Long,
    ): Boolean = wasEstablished && expected(enabled, paired, consentPaused) && recordedEpoch != consentEpoch

    private fun expected(enabled: Boolean, paired: Boolean, consentPaused: Boolean): Boolean =
        enabled && paired && !consentPaused
}
