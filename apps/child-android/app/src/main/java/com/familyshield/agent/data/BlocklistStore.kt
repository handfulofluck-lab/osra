package com.familyshield.agent.data

import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.BlocklistPackDto
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Holds the merged default-category blocklist (Feature #1): the latest GET /v1/blocklists pack
 * filtered to the rule set's blocked categories, packageId -> category. The merged map is cached
 * in memory and persisted as JSON in DataStore so a failed refresh keeps the previous list.
 * Reloads the persisted map on startup; [refresh] re-fetches and re-merges against the current
 * rule set's blocked categories.
 */
@Singleton
class BlocklistStore @Inject constructor(
    private val api: ApiService,
    private val settings: AgentSettings,
    private val moshi: Moshi,
) {
    @Volatile private var cached: Map<String, String> = emptyMap()
    @Volatile private var cachedDomains: Map<String, String> = emptyMap()

    /** Issue #1079: true once a pack has been fetched and stored on this device, even if it merged to {}. */
    @Volatile private var cachedPackStored: Boolean = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        scope.launch {
            cached = loadFromDisk() ?: emptyMap()
            val domainsJson = settings.blocklistDomainsJson()
            cachedDomains = domainsJson?.let { runCatching { mapAdapter().fromJson(it) }.getOrNull() } ?: emptyMap()
            // A persisted domains JSON is the record that a pack was stored, even when it merged to {}: the
            // file existing and being empty is a different fact from "no pack has ever arrived" (#1079).
            cachedPackStored = domainsJson != null
        }
    }

    /** Returns the blocked category for [packageId], or null when the app is not blocklisted. */
    fun isBlockedApp(packageId: String): String? = cached[packageId.trim().lowercase()]

    /** Snapshot of the current packageId -> blocked-category map. */
    fun apps(): Map<String, String> = cached

    /** Snapshot of the current domain -> blocked-category map, consumed by the DNS sinkhole (plan 1.4). */
    fun domains(): Map<String, String> = cachedDomains

    /**
     * Issue #1079: whether a blocklist pack has been fetched and stored on this device, even if it carried no
     * domain for the categories this family blocks. Without it the filter cannot tell "this family blocks
     * nothing" from "the pack never arrived", and child 2 reported both as a working filter.
     *
     * In memory it turns true as soon as a refresh succeeds; after a restart it comes from the persisted
     * domains JSON, so a save that failed leaves it false and the report stays honest (`UNPROTECTED`) rather
     * than claiming a pack the next process cannot find.
     */
    fun packStored(): Boolean = cachedPackStored

    /**
     * Fetches the blocklist pack and re-merges it against [blockedCategories]. On success the
     * new map replaces the in-memory cache and the persisted copy; on failure the previous map
     * is kept untouched. Returns true when a fresh pack was stored.
     */
    suspend fun refresh(blockedCategories: Collection<String>): Boolean {
        val pack = try {
            api.getBlocklists()
        } catch (e: CancellationException) {
            throw e // NOTE: never swallow coroutine cancellation
        } catch (e: Exception) {
            return false
        }
        val merged = merge(pack, blockedCategories)
        cached = merged
        runCatching { settings.saveBlocklistJson(mapAdapter().toJson(merged)) }
        val mergedDomains = mergeDomains(pack, blockedCategories)
        cachedDomains = mergedDomains
        runCatching { settings.saveBlocklistDomainsJson(mapAdapter().toJson(mergedDomains)) }
        cachedPackStored = true
        return true
    }

    private suspend fun loadFromDisk(): Map<String, String>? {
        val json = settings.blocklistJson() ?: return null
        return runCatching { mapAdapter().fromJson(json) }.getOrNull()
    }

    private fun mapAdapter() = moshi.adapter<Map<String, String>>(
        Types.newParameterizedType(Map::class.java, String::class.java, String::class.java),
    )

    companion object {
        private val PLAIN_MOSHI: Moshi = Moshi.Builder()
            .add(KotlinJsonAdapterFactory())
            .build()

        /**
         * Pure merge of a raw pack JSON string against the rule set's blocked [categories]:
         * packageId -> category for every Android app belonging to a blocked category. Category
         * and package matching is case-insensitive; a package listed in several blocked
         * categories keeps the first one (pack order wins). Empty or malformed packs merge to
         * an empty map.
         */
        fun merge(packJson: String, categories: Collection<String>): Map<String, String> {
            // NOTE: a static Moshi keeps this helper pure/JVM-testable without Hilt or Android.
            val pack = runCatching {
                PLAIN_MOSHI.adapter(BlocklistPackDto::class.java).fromJson(packJson)
            }.getOrNull() ?: return emptyMap()
            return merge(pack, categories)
        }

        /** domain -> category for every domain of a blocked category (same rules as [merge]; the DNS sinkhole's table). */
        fun mergeDomains(pack: BlocklistPackDto, categories: Collection<String>): Map<String, String> {
            val blocked = categories.map { it.trim().lowercase() }.toSet()
            if (blocked.isEmpty()) return emptyMap()
            val result = LinkedHashMap<String, String>()
            for (entry in pack.categories) {
                val category = entry.category.trim().lowercase()
                if (category !in blocked) continue
                for (d in entry.domains) {
                    val key = d.trim().trimEnd('.').lowercase().removePrefix("*.")
                    if (key.isNotEmpty()) result.putIfAbsent(key, category)
                }
            }
            return result
        }

        /** Map form of [merge] for callers already holding a parsed [BlocklistPackDto]. */
        fun merge(pack: BlocklistPackDto, categories: Collection<String>): Map<String, String> {
            val blocked = categories.map { it.trim().lowercase() }.toSet()
            if (blocked.isEmpty()) return emptyMap()
            val result = LinkedHashMap<String, String>()
            for (entry in pack.categories) {
                val category = entry.category.trim().lowercase()
                if (category !in blocked) continue
                for (pkg in entry.appsAndroid) {
                    result.putIfAbsent(pkg.trim().lowercase(), category)
                }
            }
            return result
        }
    }
}
