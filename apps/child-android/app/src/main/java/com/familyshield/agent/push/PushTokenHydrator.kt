package com.familyshield.agent.push

import android.util.Log
import com.familyshield.agent.data.AgentSettings
import com.google.firebase.messaging.FirebaseMessaging
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Issue #1054: proactively hydrates the FCM registration token when DataStore does not hold one yet
 * (for example, if `onNewToken` fired before pairing and was dropped before disk write completed, or
 * after an upgrade/restore).
 *
 * Must stay completely safe in FCM-free builds where `google-services.json` is absent and
 * `FirebaseApp` is uninitialized: every Firebase call is wrapped in `runCatching` and bounded by
 * [FETCH_TIMEOUT_MS].
 */
object PushTokenHydrator {
    private const val TAG = "PushTokenHydrator"

    /** Bounded wait so a stalled Play Services IPC can never block command polling. */
    internal const val FETCH_TIMEOUT_MS: Long = 5_000L

    /**
     * Pure-JVM hydration seam: returns the stored push token if non-blank; otherwise calls
     * [fetchToken], persists a non-blank token via [saveToken], and returns it. Never throws
     * (except [CancellationException]); returns null when unavailable (e.g. FCM-free builds).
     */
    internal suspend fun hydrateIfMissing(
        readStored: suspend () -> String?,
        saveToken: suspend (String) -> Unit,
        fetchToken: suspend () -> String?,
        onError: (String, Throwable) -> Unit = { _, _ -> },
    ): String? {
        val existing = readStored()?.takeIf { it.isNotBlank() }
        if (existing != null) return existing
        val fetched = try {
            fetchToken()?.takeIf { it.isNotBlank() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onError("FCM token hydration skipped", e)
            null
        } ?: return null
        try {
            saveToken(fetched)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onError("Failed to persist hydrated push token", e)
        }
        return fetched
    }

    /** Hydrates and persists the FCM token into [settings] if none is stored yet. */
    suspend fun hydrateIfMissing(settings: AgentSettings): String? = hydrateIfMissing(
        readStored = { settings.pushToken() },
        saveToken = { settings.savePushToken(it) },
        fetchToken = { fetchFirebaseToken() },
        onError = { message, error -> Log.d(TAG, "$message: ${error.message}") },
    )

    private suspend fun fetchFirebaseToken(): String? = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
        val task = runCatching { FirebaseMessaging.getInstance().token }.getOrNull()
            ?: return@withTimeoutOrNull null
        suspendCancellableCoroutine { cont ->
            runCatching {
                task.addOnSuccessListener { token ->
                    if (cont.isActive) cont.resume(token)
                }.addOnFailureListener {
                    if (cont.isActive) cont.resume(null)
                }.addOnCanceledListener {
                    if (cont.isActive) cont.resume(null)
                }
            }.onFailure {
                if (cont.isActive) cont.resume(null)
            }
        }
    }
}
