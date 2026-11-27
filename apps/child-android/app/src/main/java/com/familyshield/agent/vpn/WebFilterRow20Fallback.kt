package com.familyshield.agent.vpn

import com.familyshield.agent.BuildConfig

/**
 * Default-off contingency switches for device row 20 (#1051 / #1224).
 *
 * When Chrome's internal DNS/socket pool keeps an already-open site loading past #1234's 1 s
 * `MODE_SINKHOLE_ALL` hop, two independent remedies are wired behind compile-time flags that
 * default to `false`:
 *  1. [extendedHopEnabled] (`-Posra.row20Fallback=true`): lengthens the transient sinkhole window
 *     from 1 s to [DEFAULT_EXTENDED_HOP_MS] (configurable via `-Posra.row20HopPauseMs=`, clamped
 *     to [MIN_HOP_MS]..[MAX_HOP_MS]).
 *  2. [tabCloseEnabled] (`-Posra.row20TabClose=true`, or enabled alongside `-Posra.row20Fallback=true`):
 *     evicts an open foreground browser tab whose displayed host now resolves to [DnsFilterPolicy.Action.SINK]
 *     (#1051 option c), without logging or persisting any URL or host.
 */
object WebFilterRow20Fallback {
    const val DEFAULT_EXTENDED_HOP_MS: Long = 5_000L
    const val MIN_HOP_MS: Long = WebFilterConnectionReset.DEFAULT_PAUSE_MS
    const val MAX_HOP_MS: Long = 15_000L

    data class Config(
        val extendedHopEnabled: Boolean = BuildConfig.ROW20_WEB_BLOCK_FALLBACK,
        val extendedHopPauseMs: Long = BuildConfig.ROW20_WEB_BLOCK_HOP_PAUSE_MS,
        val tabCloseEnabled: Boolean = BuildConfig.ROW20_WEB_BLOCK_TAB_CLOSE,
    )

    @Volatile
    private var overrideForTest: Config? = null

    internal fun setOverrideForTest(config: Config?) {
        overrideForTest = config
    }

    fun currentConfig(): Config = overrideForTest ?: Config()

    fun effectiveHopPauseMs(config: Config = currentConfig()): Long =
        if (config.extendedHopEnabled) {
            config.extendedHopPauseMs.coerceIn(MIN_HOP_MS, MAX_HOP_MS)
        } else {
            WebFilterConnectionReset.DEFAULT_PAUSE_MS
        }

    fun isTabCloseEnabled(config: Config = currentConfig()): Boolean = config.tabCloseEnabled
}
