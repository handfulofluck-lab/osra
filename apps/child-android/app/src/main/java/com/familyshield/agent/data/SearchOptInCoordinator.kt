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
 * Enforces four invariants before search capture or upload is allowed:
 * 1. Startup disk-cache loads (`RuleRepository.kt:97`) NEVER enable search capture or unverified
 *    uploads on their own: `freshSyncConfirmed` remains `false` until a live server sync runs.
 * 2. Enabling requires `searchMonitoring == true`, a positive server-issued
 *    `searchMonitoringRevision`, and clean persistence of every state key (`purge_pending`,
 *    `opt_in_rev`, `opt_in_enabled`, `rules_version`). Any DAO error keeps `committed = false`.
 * 3. Every queued search row and `SearchEventDto` binds to the server-issued
 *    `searchMonitoringRevision`, which `POST /v1/content/search-event` verifies against current
 *    server state (`409` on missed offline opt-out + re-enable).
 * 4. Opt-out, `forgetRules()`, or server revision advances arm `KEY_SEARCH_PURGE_PENDING`,
 *    disqualify prior revisions immediately, and purge stale queued search rows.
 */
class SearchOptInCoordinator(
    private val agentStateDao: AgentStateDao,
    private val pendingScanDao: PendingScanDao,
) {

    @Volatile private var freshSyncConfirmed: Boolean = false
    @Volatile private var committed: Boolean = false
    @Volatile private var revision: Long = 0L

    fun isSearchMonitoringEnabled(ruleSet: RuleSetDto?): Boolean =
        freshSyncConfirmed && ruleSet?.searchMonitoring == true && committed && revision > 0L

    fun isFreshSyncConfirmed(): Boolean = freshSyncConfirmed

    fun currentRevision(): Long = if (freshSyncConfirmed && committed && revision > 0L) revision else 0L

    /**
     * Startup load of cached disk rules (`RuleRepository.kt:97`). Keeps `freshSyncConfirmed = false`
     * so cached enabled rules never authorize capture or unverified uploads before a server sync.
     * Still enforces pending disabled/purge cleanup if cached disk rules already show opt-out.
     */
    suspend fun onStartupLoaded(diskRules: RuleSetDto?) {
        freshSyncConfirmed = false
        committed = false
        revision = 0L
        if (diskRules?.searchMonitoring == true) {
            return
        }
        try {
            val persistedEnabled = agentStateDao.get(KEY_SEARCH_OPT_IN_ENABLED) == 1L
            val purgePending = (agentStateDao.get(KEY_SEARCH_PURGE_PENDING) ?: 0L) != 0L
            if (persistedEnabled || purgePending) {
                val persistedRev = agentStateDao.get(KEY_SEARCH_OPT_IN_REV) ?: 0L
                persistDisabledLocked(persistedRev, diskRules?.rulesVersion?.toLong() ?: -1L)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            committed = false
            revision = 0L
        }
    }

    suspend fun onRulesFetched(previous: RuleSetDto?, updated: RuleSetDto) {
        val serverRev = updated.searchMonitoringRevision.toLong()
        if (updated.searchMonitoring != true || serverRev <= 0L) {
            committed = false
            revision = 0L
        }
        try {
            val persistedRev = agentStateDao.get(KEY_SEARCH_OPT_IN_REV) ?: 0L
            val persistedEnabled = agentStateDao.get(KEY_SEARCH_OPT_IN_ENABLED) == 1L
            val persistedRulesVersion = agentStateDao.get(KEY_SEARCH_RULES_VERSION)
            val purgePending = (agentStateDao.get(KEY_SEARCH_PURGE_PENDING) ?: 0L) != 0L

            if (updated.searchMonitoring != true || serverRev <= 0L) {
                freshSyncConfirmed = true
                val targetRev = maxOf(persistedRev, serverRev)
                if (previous?.searchMonitoring == true || persistedEnabled || purgePending || persistedRev != targetRev) {
                    persistDisabledLocked(targetRev, updated.rulesVersion.toLong())
                }
                return
            }

            val sameGrant = persistedEnabled &&
                persistedRev == serverRev &&
                !purgePending &&
                persistedRulesVersion == updated.rulesVersion.toLong()
            if (sameGrant) {
                revision = serverRev
                committed = true
                freshSyncConfirmed = true
            } else {
                commitEnabledGrantLocked(serverRev = serverRev, rulesVersion = updated.rulesVersion.toLong())
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            committed = false
            revision = 0L
        }
    }

    suspend fun onForgetRules() {
        freshSyncConfirmed = true
        committed = false
        revision = 0L
        try {
            val persistedRev = agentStateDao.get(KEY_SEARCH_OPT_IN_REV) ?: 0L
            persistDisabledLocked(persistedRev, -1L)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            committed = false
            revision = 0L
        }
    }

    private suspend fun persistDisabledLocked(targetRev: Long, rulesVersion: Long) {
        committed = false
        revision = 0L
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_PURGE_PENDING, 1L))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_OPT_IN_REV, targetRev))
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

    private suspend fun commitEnabledGrantLocked(serverRev: Long, rulesVersion: Long) {
        committed = false
        revision = 0L
        val activeSource = ScanQueuePolicy.searchSource(serverRev)
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_PURGE_PENDING, 1L))
        agentStateDao.set(AgentStateEntity(KEY_SEARCH_OPT_IN_REV, serverRev))
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
        revision = serverRev
        committed = true
        freshSyncConfirmed = true
    }

    companion object {
        const val KEY_SEARCH_OPT_IN_REV: String = RuleRepository.KEY_SEARCH_OPT_IN_REV
        const val KEY_SEARCH_OPT_IN_ENABLED: String = RuleRepository.KEY_SEARCH_OPT_IN_ENABLED
        const val KEY_SEARCH_PURGE_PENDING: String = RuleRepository.KEY_SEARCH_PURGE_PENDING
        const val KEY_SEARCH_RULES_VERSION: String = RuleRepository.KEY_SEARCH_RULES_VERSION
    }
}
