package com.familyshield.agent.di

import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.BlocklistStore
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.commands.CommandDispatcher
import com.familyshield.agent.comms.CommsLogger
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.telemetry.UsageReporter
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * Entry point for WorkManager workers (which are not Hilt-injected); workers pull their
 * dependencies via [dagger.hilt.android.EntryPointAccessors.fromApplication].
 */
@EntryPoint
@InstallIn(SingletonComponent::class)
interface WorkerEntryPoint {
    /** Rule repository for sync/reset workers. */
    fun ruleRepository(): RuleRepository

    /** Merged default-category blocklist store (Feature #1). */
    fun blocklistStore(): BlocklistStore

    /** Usage reporter for the telemetry worker. */
    fun usageReporter(): UsageReporter

    /** Room database (DAOs). */
    fun database(): FamilyShieldDatabase

    /** Retrofit API. */
    fun apiService(): ApiService

    /** Command dispatcher for the polling worker (§14.2). */
    fun commandDispatcher(): CommandDispatcher

    /** DataStore-backed settings. */
    fun agentSettings(): AgentSettings

    /** ADR-0008 §3: workers must not upload while consent is withdrawn. */
    fun consentState(): ConsentState

    /** Call/SMS logger for the telemetry-worker flush backstop (Feature #6). */
    fun commsLogger(): CommsLogger
}
