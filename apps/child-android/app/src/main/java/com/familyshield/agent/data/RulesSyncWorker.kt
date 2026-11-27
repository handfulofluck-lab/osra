package com.familyshield.agent.data

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors

/** Periodically refreshes the rule set from the backend (RuleRepository.refresh). */
class RulesSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** Refreshes rules then the blocklist pack; retries on network failure. */
    override suspend fun doWork(): Result {
        return try {
            val entryPoint = EntryPointAccessors.fromApplication(
                applicationContext,
                WorkerEntryPoint::class.java,
            )
            // Feature #1 / #864: the category pack is re-merged inside `RuleRepository.refresh()` now, under
            // the same mutex and before the #444 C4 listeners, so it is fresh on every path — including the one
            // where the VPN tunnel is not running. Refreshing it here as well was a second `GET /v1/blocklists`
            // per sync (Antigravity, #922 review).
            val rules = entryPoint.ruleRepository()
            val beforeWebFilter = runCatching { rules.currentRules()?.webFilter }.getOrNull()
            val afterWebFilter = rules.refresh()?.webFilter
            // Plan 1.4: the sinkhole re-reads the web filter (domains, SafeSearch, YouTube mode) after every sync.
            if (com.familyshield.agent.vpn.VpnState.isEnabled(applicationContext)) {
                runCatching { com.familyshield.agent.vpn.FilterVpnService.reload(applicationContext) }
                runCatching {
                    com.familyshield.agent.vpn.WebFilterConnectionReset.resetIfNeeded(
                        context = applicationContext,
                        rules = rules,
                        consent = entryPoint.consentState(),
                        before = beforeWebFilter,
                        after = afterWebFilter,
                    )
                }
            }
            Result.success()
        } catch (e: Exception) {
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    companion object {
        /** Unique work name for the periodic rules sync. */
        const val WORK_NAME: String = "rules_sync"
    }
}
