package com.familyshield.agent.recovery

import android.content.Context

/**
 * Durable per-window revival attempt counter (osra-security#78, K31 review).
 *
 * Stored in `SharedPreferences` rather than an in-memory field so a process kill + restart cannot
 * wipe the attempt count and loop `onDestroy -> 1.5 s alarm -> ServiceRecovery -> killed` forever.
 */
internal object ServiceRevivalState {

    private const val PREFS = "familyshield_revival"
    private const val KEY_WINDOW_START_ELAPSED = "window_start_elapsed_ms"
    private const val KEY_ATTEMPT_COUNT = "attempt_count"
    private const val KEY_CAP_LOGGED = "cap_logged"
    private const val KEY_BOOT_COUNT = "boot_count"

    fun read(context: Context): ServiceRevivalPolicy.WindowState {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return ServiceRevivalPolicy.WindowState(
            windowStartElapsedMs = prefs.getLong(KEY_WINDOW_START_ELAPSED, 0L),
            attemptCount = prefs.getInt(KEY_ATTEMPT_COUNT, 0),
            capLogged = prefs.getBoolean(KEY_CAP_LOGGED, false),
            bootCount = prefs.getInt(KEY_BOOT_COUNT, ServiceRevivalPolicy.NO_BOOT),
        )
    }

    fun write(context: Context, state: ServiceRevivalPolicy.WindowState) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_WINDOW_START_ELAPSED, state.windowStartElapsedMs)
            .putInt(KEY_ATTEMPT_COUNT, state.attemptCount)
            .putBoolean(KEY_CAP_LOGGED, state.capLogged)
            .putInt(KEY_BOOT_COUNT, state.bootCount)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }
}
