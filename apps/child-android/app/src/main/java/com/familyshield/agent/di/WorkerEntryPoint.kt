package com.familyshield.agent.di

import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.BlocklistStore
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.commands.CommandPoller
import com.familyshield.agent.comms.CommsCapture
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

    /** Roadmap 3.4: installed-launchable-app inventory, uploaded on the telemetry tick when changed. */
    fun installedAppsReporter(): com.familyshield.agent.apps.InstalledAppsReporter

    /** Room database (DAOs). */
    fun database(): FamilyShieldDatabase

    /** Retrofit API. */
    fun apiService(): ApiService

    /** One command fetch-and-dispatch pass (§14.2, #319) — shared by the poll worker and the push wake. */
    fun commandPoller(): CommandPoller

    /** DataStore-backed settings. */
    fun agentSettings(): AgentSettings

    /** ADR-0008 §3: workers must not upload while consent is withdrawn. */
    fun consentState(): ConsentState

    /** Call/SMS logger for the telemetry-worker flush backstop (Feature #6). */
    fun commsCapture(): CommsCapture

    /** Device-admin façade (ADR-0010) for the tamper checks. */
    fun deviceAdminManager(): com.familyshield.agent.security.DeviceAdminManager

    /** Parent-PIN store (ADR-0010). */
    fun parentPinStore(): com.familyshield.agent.security.ParentPinStore

    /** Plan 2.6: the durable scan queue, for ScanFlushWorker. */
    fun socialScanQueue(): com.familyshield.agent.social.SocialScanQueue

    /** Issue #465 review: the unlink, so a start after a half-finished one can finish it. */
    fun deviceUnlinker(): com.familyshield.agent.network.DeviceUnlinker
}
