package com.familyshield.agent.enforcement

import android.content.Context
import android.content.Intent
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Shows the full-screen block overlay (BlockActivity) for a package, debounced to once per
 * 2 s per package, and never for the agent's own package (prevents overlay loops).
 */
@Singleton
class AppBlocker @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val lock = Any()
    private val lastShownMs = HashMap<String, Long>()

    /** Shows the "blocked by your parent" screen for [pkg]. */
    fun showBlockScreen(pkg: String) = show(pkg, BlockActivity.REASON_BLOCKED)

    /** Shows the "daily limit reached" screen for [pkg]. */
    fun showTimeLimitScreen(pkg: String) = show(pkg, BlockActivity.REASON_TIME_LIMIT)

    private fun show(pkg: String, reason: String) {
        if (pkg.isBlank() || pkg == context.packageName) return
        synchronized(lock) {
            val now = System.currentTimeMillis()
            // NOTE: purge stale entries so the map cannot grow unboundedly over weeks of uptime.
            if (lastShownMs.size > MAX_TRACKED_PACKAGES) {
                val it = lastShownMs.entries.iterator()
                while (it.hasNext()) {
                    if (now - it.next().value > DEBOUNCE_MS) it.remove()
                }
            }
            val last = lastShownMs[pkg] ?: 0L
            // NOTE: a backwards system clock (now < last) must not suppress the overlay forever.
            if (now - last in 0 until DEBOUNCE_MS) return
            lastShownMs[pkg] = now
        }
        val intent = Intent(context, BlockActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(BlockActivity.EXTRA_PACKAGE, pkg)
            .putExtra(BlockActivity.EXTRA_REASON, reason)
        runCatching { context.startActivity(intent) }
    }

    companion object {
        private const val DEBOUNCE_MS = 2_000L
        private const val MAX_TRACKED_PACKAGES = 200
    }
}
