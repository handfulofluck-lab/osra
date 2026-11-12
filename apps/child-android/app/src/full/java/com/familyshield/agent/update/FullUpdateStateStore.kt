package com.familyshield.agent.update

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first

private val Context.fullUpdateDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "full_update_state",
)

/**
 * ADR-0039 amendment row 2: the highest `versionCode` and `releasedAt` this phone has ever accepted, so a
 * replayed or frozen manifest is refused even after it expires.
 *
 * [recordAccepted] can only move the marks forward: [FullUpdatePolicy.accept] refuses anything below the
 * pair it is given, and the caller writes only a manifest that call accepted.
 */
class FullUpdateStateStore(private val context: Context) {

    data class HighWater(val highestSeenVersionCode: Long, val highestSeenReleasedAt: String)

    suspend fun highWater(): HighWater {
        val preferences: Preferences = context.fullUpdateDataStore.data.first()
        return HighWater(
            highestSeenVersionCode = preferences[KEY_HIGHEST_VERSION_CODE] ?: 0L,
            highestSeenReleasedAt = preferences[KEY_HIGHEST_RELEASED_AT] ?: "",
        )
    }

    suspend fun recordAccepted(manifest: FullUpdateManifest) {
        context.fullUpdateDataStore.edit { preferences: MutablePreferences ->
            preferences[KEY_HIGHEST_VERSION_CODE] = manifest.versionCode
            preferences[KEY_HIGHEST_RELEASED_AT] = manifest.releasedAt
        }
    }

    private companion object {
        val KEY_HIGHEST_VERSION_CODE: Preferences.Key<Long> = longPreferencesKey("highest_seen_version_code")
        val KEY_HIGHEST_RELEASED_AT: Preferences.Key<String> = stringPreferencesKey("highest_seen_released_at")
    }
}
