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
            val rules = entryPoint.ruleRepository().refresh()
            // Feature #1: re-merge the default-category pack against the fresh rule set's blocked
            // categories; a pack fetch failure keeps the previously stored merged list.
            val blocked = rules?.webFilter?.blockedCategories ?: emptyList()
            entryPoint.blocklistStore().refresh(blocked)
            // Plan 1.4: the sinkhole re-reads the web filter (domains, SafeSearch, YouTube mode) after every sync.
            if (com.familyshield.agent.vpn.VpnState.isEnabled(applicationContext)) {
                runCatching { com.familyshield.agent.vpn.FilterVpnService.reload(applicationContext) }
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
