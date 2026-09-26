package com.familyshield.agent.network.dto

/**
 * Moshi models mirroring the shared-types BlocklistPack (GET /v1/blocklists, Feature #1).
 * Pure Kotlin so the merge logic and unit tests run on the JVM.
 */
data class BlocklistPackDto(
    val version: Int = 0,
    val updatedAt: String = "",
    val categories: List<BlocklistCategoryDto> = emptyList(),
)

/** One category entry of the pack; [appsAndroid] are package ids, [appsWindows] process names. */
data class BlocklistCategoryDto(
    val category: String = "",
    val domains: List<String> = emptyList(),
    val appsAndroid: List<String> = emptyList(),
    val appsWindows: List<String> = emptyList(),
)
