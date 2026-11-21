package com.familyshield.agent.data

import com.familyshield.agent.data.db.AgentStateDao
import com.familyshield.agent.data.db.AgentStateEntity
import com.familyshield.agent.data.db.PendingScanDao
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.social.ScanQueuePolicy
import kotlinx.coroutines.CancellationException

/**
 * Production coordinator for durable `searchMonitoring` opt-in state (`osra-security#59`).
 *
 * Enforces three invariants before search capture/upload is allowed:
 * 1. Search transmission stays disabled (`isSearchMonitoringEnabled == false`) until the transition
 *    state (`rev`, `enabled`, `rulesVersion`, `purgePending`) commits cleanly to [AgentStateDao].
 *    Persistence errors are never silently treated as enabled.
 * 2. Opt-out and `forgetRules()` immediately disqualify the active in-memory revision, persist
 *    [KEY_SEARCH_PURGE_PENDING], rotate the revision, and purge queued search rows.
 * 3. Any advance/change in [RuleSetDto.rulesVersion] rotates the durable revision and purges prior
 *    search rows conservatively, so a device that missed an offline opt-out + re-enable cannot reuse
 *    pre-opt-out queued rows.
 */
class SearchOptInCoordinator(
    private val agentStateDao: AgentStateDao,
    private val pendingScanDao: PendingScanDao,
) {

    @Volatile private var committed: Boolean = false
    @Volatile private var revision: Long = 0L
    @Volatile private var observedMaxRev: Long = 0L

    fun isSearchMonitoringEnabled(ruleSet: RuleSetDto?): Boolean =
        ruleSet?.searchMonitoring == true && committed && revision > 0L

    fun currentRevision(): Long = if (committed && revision > 0L) revision else 0L

    suspend fun onStartupLoaded(diskRules: RuleSetDto?) {
        committed = false
        revision = 0L
        try {
            val persistedRev = agentStateDao.get(KEY_SEARCH_OPT_IN_REV) ?: 0L
            observedMaxRev = maxOf(observedMaxRev, persistedRev)
            val persistedEnabled = agentStateDao.get(KEY_SEARCH_OPT_IN_ENABLED) == 1L
            val persistedRulesVersion = agentStateDao.get(KEY_SEARCH_RULES_VERSION)
            val purgePending = (agentStateDao.get(KEY_SEARCH_PURGE_PENDING) ?: 0L) != 0L

            if (diskRules?.searchMonitoring != true) {
                if (persistedEnabled || purgePending) {
                    persistDisabledLocked(persistedRev, diskRules?.rulesVersion?.toLong() ?: -1L)
                }
                return
            }

            if (persistedEnabled &&
                persistedRev > 0L &&
                persistedRulesVersion == diskRules.rulesVersion.toLong() &&
                !purgePending
            ) {
                revision = persistedRev
                committed = true
            } else {
                rotateAndCommitEnabledLocked(persistedRev, diskRules.rulesVersion.toLong())
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            committed = false
            revision = 0L
        }
    }

    suspend fun onRulesFetched(previous: RuleSetDto?, updated: RuleSetDto) {
        if (updated.searchMonitoring != true) {
            committed = false
            revision = 0L
        }
        try {
            val persistedRev = agentStateDao.get(KEY_SEARCH_OPT_IN_REV) ?: 0L
            observedMaxRev = maxOf(observedMaxRev, persistedRev)
            val persistedEnabled = agentStateDao.get(KEY_SEARCH_OPT_IN_ENABLED) == 1L
            val persistedRulesVersion = agentStateDao.get(KEY_SEARCH_RULES_VERSION)
            val purgePending = (agentStateDao.get(KEY_SEARCH_PURGE_PENDING) ?: 0L) != 0L

            if (updated.searchMonitoring != true) {
                val wasEnabled = previous?.searchMonitoring == true || persistedEnabled
                if (wasEnabled || purgePending || persistedRev == 0L) {
                    persistDisabledLocked(persistedRev, updated.rulesVersion.toLong())
                }
                return
            }

            val wasEnabled = previous?.searchMonitoring == true && persistedEnabled && !purgePending && persistedRev > 0L
            val sameVersion = persistedRulesVersion != null && persistedRulesVersion == updated.rulesVersion.toLong()
            if (wasEnabled && sameVersion) {
                revision = persistedRev
                committed = true
            } else {
                rotateAndCommitEnabledLocked(persistedRev, updated.rulesVersion.toLong())
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            committed = false
            revision = 0L
        }
    }

    suspend fun onForgetRules() {
        committed = false
        revision = 0L
        try {
            val persistedRev = agentStateDao.get(KEY_SEARCH_OPT_IN_REV) ?: 0L
            observedMaxRev = maxOf(observedMaxRev, persistedRev)
            persistDisabledLocked(persistedRev, -1L)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            committed = false
            revision = 0L
        }
    }

    private suspend fun persistDisabledLocked(persistedRev: Long, rulesVersion: Long) {
        committed = false
        revision = 0L
        val nextRev = maxOf(persistedRev, observedMaxRev) + 1L
        observedMaxRev = nextRev
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_PURGE_PENDING, 1L))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_OPT_IN_REV, nextRev))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_OPT_IN_ENABLED, 0L))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_RULES_VERSION, rulesVersion))
        try {
            pendingScanDao.deleteAllSearches()
            agentStateDao.set(AgentStateEntity(KEY_SEARCH_PURGE_PENDING, 0L))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Keep KEY_SEARCH_PURGE_PENDING = 1L so SocialScanQueue stays fail-closed until cleanup succeeds.
        }
    }

    private suspend fun rotateAndCommitEnabledLocked(persistedRev: Long, rulesVersion: Long) {
        committed = false
        revision = 0L
        val nextRev = maxOf(persistedRev, observedMaxRev) + 1L
        observedMaxRev = nextRev
        val activeSource = ScanQueuePolicy.searchSource(nextRev)
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_PURGE_PENDING, 1L))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_OPT_IN_REV, nextRev))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_OPT_IN_ENABLED, 1L))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_RULES_VERSION, rulesVersion))
        try {
            pendingScanDao.deleteStaleSearches(activeSource)
            agentStateDao.set(AgentStateEntity(KEY_SEARCH_PURGE_PENDING, 0L))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Keep KEY_SEARCH_PURGE_PENDING = 1L so SocialScanQueue blocks search enqueue/flush until cleanup succeeds.
        }
        revision = nextRev
        committed = true
    }

    companion object {
        const val KEY_SEARCH_OPT_IN_REV: String = RuleRepository.KEY_SEARCH_OPT_IN_REV
        const val KEY_SEARCH_OPT_IN_ENABLED: String = RuleRepository.KEY_SEARCH_OPT_IN_ENABLED
        const val KEY_SEARCH_PURGE_PENDING: String = RuleRepository.KEY_SEARCH_PURGE_PENDING
        const val KEY_SEARCH_RULES_VERSION: String = RuleRepository.KEY_SEARCH_RULES_VERSION
    }
}
