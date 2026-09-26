package com.familyshield.agent.data

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors

/** Resets daily usage counters at local midnight (see RuleRepository.resetIfNewDay). */
class MidnightResetWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** Resets the counters when the date has rolled over; always succeeds. */
    override suspend fun doWork(): Result {
        EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
            .ruleRepository()
            .resetIfNewDay()
        return Result.success()
    }

    companion object {
        /** Unique work name for the periodic midnight reset. */
        const val WORK_NAME: String = "midnight_reset"
    }
}
