package com.familyshield.agent.update

import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.util.Log
import androidx.core.content.pm.PackageInfoCompat
import com.familyshield.agent.BuildConfig
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody

/** What one check ended as. Every [Refused] variant has already been logged as `update_refused:<reason>`. */
sealed interface FullUpdateOutcome {
    data class InstallRequested(val versionCode: Long) : FullUpdateOutcome
    data class Refused(val reason: String, val informational: Boolean) : FullUpdateOutcome
}

/**
 * The Android adapter over [FullUpdatePolicy] (ADR-0039 D5, amendment 2026-11-12 rows 1–9). It is the
 * only class in the app that touches `PackageInstaller` — `PackageInstallerSingleSourceTest` pins that —
 * so no server command, push, intent or deep link reaches an install except through a manifest the trust
 * core accepted.
 *
 * Nothing here throws to its caller: a network fault, a hostile response or a missing grant all end as
 * `FullUpdateOutcome` and a `update_refused:<reason>` log line.
 */
class FullUpdater(
    private val context: Context,
    private val keys: Map<String, String>,
    private val state: FullUpdateStateStore,
    private val verifier: ManifestVerifier = TinkEd25519Verifier,
    private val client: OkHttpClient = noRedirectClient(),
    private val now: () -> Instant = Instant::now,
) {

    /**
     * Fetches, verifies, accepts and — only then — installs. The informational outcomes are
     * `manifest_key_unavailable` (the compiled-in keys are still placeholders) and
     * `install_grant_missing`; neither is a crash and neither is worth a retry.
     */
    suspend fun check(statusIntent: IntentSender): FullUpdateOutcome = try {
        when {
            !context.packageManager.canRequestPackageInstalls() ->
                refuse(REASON_INSTALL_GRANT_MISSING, informational = true)
            else -> evaluate(statusIntent)
        }
    } catch (e: Exception) {
        Log.e(TAG, "update_refused:$REASON_CHECK_FAILED", e)
        FullUpdateOutcome.Refused(REASON_CHECK_FAILED, informational = false)
    }

    private suspend fun evaluate(statusIntent: IntentSender): FullUpdateOutcome {
        val publicKeys: Map<String, ByteArray> = publicKeys()
        if (publicKeys.isEmpty()) return refuse(REASON_MANIFEST_KEY_UNAVAILABLE, informational = true)

        val manifestBytes: ByteArray = when (val fetched = fetch(MANIFEST_URL)) {
            is Fetch.Body -> fetched.bytes
            is Fetch.Failed -> return refuse(fetched.reason)
        }
        val signatureBase64: String = when (val fetched = fetch(SIGNATURE_URL)) {
            is Fetch.Body -> String(fetched.bytes, Charsets.US_ASCII).trim()
            is Fetch.Failed -> return refuse(fetched.reason)
        }

        val manifest: FullUpdateManifest = when (
            val decision: UpdateDecision =
                FullUpdatePolicy.verifyAndParse(manifestBytes, signatureBase64, publicKeys, verifier)
        ) {
            is UpdateDecision.Refused -> return refuse(decision.reason.name)
            is UpdateDecision.Accepted -> decision.manifest
        }

        val highWater: FullUpdateStateStore.HighWater = state.highWater()
        val facts: FullUpdatePolicy.DeviceFacts = FullUpdatePolicy.DeviceFacts(
            ownPackageName = BuildConfig.APPLICATION_ID,
            installedVersionCode = installedVersionCode(),
            highestSeenVersionCode = highWater.highestSeenVersionCode,
            highestSeenReleasedAt = highWater.highestSeenReleasedAt,
            nowIso = now().toString(),
            deviceSdk = Build.VERSION.SDK_INT,
        )
        when (val decision: UpdateDecision = FullUpdatePolicy.accept(manifest, facts)) {
            is UpdateDecision.Refused -> return refuse(decision.reason.name)
            is UpdateDecision.Accepted -> Unit
        }
        state.recordAccepted(manifest)
        return install(manifest, statusIntent)
    }

    /**
     * The archive is hashed while the same bytes are written into the open session (amendment row 6):
     * the body is read off the wire once, and each chunk goes into the digest and the session together.
     * The copy in [context]'s cache directory exists only because `getPackageArchiveInfo` takes a path
     * for row 5's package check and row 7's certificate check; it is deleted in `finally` either way.
     *
     * On API 31+ the session asks for `USER_ACTION_NOT_REQUIRED`, which Android honours only when this
     * app is the installer of record. The first install came from the browser, so the first update still
     * asks the child once; on API 34+ `setRequestUpdateOwnership(true)` claims that role, so later
     * updates can be silent.
     */
    private fun install(manifest: FullUpdateManifest, statusIntent: IntentSender): FullUpdateOutcome {
        if (manifest.size > APK_MAX_BYTES) return refuse(REASON_RESPONSE_TOO_LARGE)
        val installer: PackageInstaller = context.packageManager.packageInstaller
        val sessionParams: PackageInstaller.SessionParams =
            PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(BuildConfig.APPLICATION_ID)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    setRequestUpdateOwnership(true)
                }
            }
        val session: PackageInstaller.Session = installer.openSession(installer.createSession(sessionParams))
        val archive: File = File(context.cacheDir, "full-update-${manifest.versionCode}.apk")
        var committed: Boolean = false
        try {
            val streamed: Streamed = streamIntoSession(session, archive, manifest)
            FullUpdatePolicy.checkDownload(manifest.sha256, streamed.sha256, manifest.size, streamed.bytes)
                ?.let { refusal: UpdateRefusal -> throw InstallRefusal(refusal.name) }
            val archiveInfo: PackageInfo =
                packageArchiveInfo(archive) ?: throw InstallRefusal(REASON_MALFORMED_ARCHIVE)
            if (archiveInfo.packageName != BuildConfig.APPLICATION_ID) {
                throw InstallRefusal(UpdateRefusal.wrong_package.name)
            }
            FullUpdatePolicy.checkSigner(hasOwnSigner(archiveInfo))
                ?.let { refusal: UpdateRefusal -> throw InstallRefusal(refusal.name) }
            session.commit(statusIntent)
            committed = true
            return FullUpdateOutcome.InstallRequested(manifest.versionCode)
        } catch (e: InstallRefusal) {
            return refuse(e.reason)
        } catch (e: Exception) {
            Log.e(TAG, "update_refused:$REASON_INSTALL_FAILED", e)
            return FullUpdateOutcome.Refused(REASON_INSTALL_FAILED, informational = false)
        } finally {
            if (!committed) runCatching { session.abandon() }
            runCatching { session.close() }
            if (archive.exists() && !archive.delete()) {
                Log.w(TAG, "could not delete the temp archive ${archive.name}")
            }
        }
    }

    private fun streamIntoSession(
        session: PackageInstaller.Session,
        archive: File,
        manifest: FullUpdateManifest,
    ): Streamed {
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        val request: Request = Request.Builder().url(manifest.url).get().build()
        var total: Long = 0L
        try {
            session.openWrite(SESSION_ENTRY, 0L, manifest.size).use { sessionOut: OutputStream ->
                archive.outputStream().use { fileOut: OutputStream ->
                    client.newCall(request).execute().use { response: Response ->
                        if (!response.isSuccessful) throw InstallRefusal(REASON_DOWNLOAD_FAILED)
                        val body: ResponseBody =
                            response.body ?: throw InstallRefusal(REASON_DOWNLOAD_FAILED)
                        val source = body.byteStream()
                        val buffer = ByteArray(BUFFER_BYTES)
                        while (true) {
                            val read: Int = source.read(buffer)
                            if (read < 0) break
                            total += read
                            if (total > APK_MAX_BYTES) throw InstallRefusal(REASON_RESPONSE_TOO_LARGE)
                            digest.update(buffer, 0, read)
                            sessionOut.write(buffer, 0, read)
                            fileOut.write(buffer, 0, read)
                        }
                    }
                }
                session.fsync(sessionOut)
            }
        } catch (e: IOException) {
            throw InstallRefusal(REASON_DOWNLOAD_FAILED)
        }
        return Streamed(bytes = total, sha256 = hex(digest.digest()))
    }

    private fun packageArchiveInfo(archive: File): PackageInfo? {
        val flags: Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        return context.packageManager.getPackageArchiveInfo(archive.absolutePath, flags)
    }

    /**
     * Rows 5 and 7: the archive's signer must be ours. API 28+ asks `hasSigningCertificate`, so a planned
     * v3 rotation of the release key is still accepted; on API 26 and 27, where that call does not exist,
     * the archive's signing certificate bytes are compared with the installed app's own `signatures`.
     */
    private fun hasOwnSigner(archiveInfo: PackageInfo): Boolean {
        val packageManager: PackageManager = context.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signers: Array<Signature> = archiveInfo.signingInfo?.apkContentsSigners ?: return false
            return signers.any { signer: Signature ->
                packageManager.hasSigningCertificate(
                    BuildConfig.APPLICATION_ID,
                    MessageDigest.getInstance("SHA-256").digest(signer.toByteArray()),
                    PackageManager.CERT_INPUT_SHA256,
                )
            }
        }
        val own: List<Signature> = ownSignatures(packageManager)
        @Suppress("DEPRECATION")
        val archiveSigners: Array<Signature> = archiveInfo.signatures ?: return false
        return archiveSigners.any { archiveSigner: Signature ->
            own.any { ownSigner: Signature ->
                ownSigner.toByteArray().contentEquals(archiveSigner.toByteArray())
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun ownSignatures(packageManager: PackageManager): List<Signature> =
        packageManager.getPackageInfo(BuildConfig.APPLICATION_ID, PackageManager.GET_SIGNATURES)
            .signatures?.toList() ?: emptyList()

    private fun installedVersionCode(): Long = PackageInfoCompat.getLongVersionCode(
        context.packageManager.getPackageInfo(BuildConfig.APPLICATION_ID, 0),
    )

    private fun publicKeys(): Map<String, ByteArray> = keys.mapNotNull { entry: Map.Entry<String, String> ->
        FullUpdatePolicy.publicKeyFromRawBase64(entry.value)?.let { publicKey: ByteArray ->
            entry.key to publicKey
        }
    }.toMap()

    private fun fetch(url: String): Fetch {
        if (!FullUpdatePolicy.isAllowedUrl(url)) return Fetch.Failed(UpdateRefusal.off_site_url.name)
        val request: Request = Request.Builder().url(url).get().build()
        return try {
            client.newCall(request).execute().use { response: Response ->
                if (!response.isSuccessful) return Fetch.Failed(REASON_FETCH_FAILED)
                val body: ResponseBody = response.body ?: return Fetch.Failed(REASON_FETCH_FAILED)
                Fetch.Body(readCapped(body))
            }
        } catch (e: ResponseTooLarge) {
            Fetch.Failed(REASON_RESPONSE_TOO_LARGE)
        } catch (e: IOException) {
            Fetch.Failed(REASON_NETWORK_ERROR)
        }
    }

    private fun readCapped(body: ResponseBody): ByteArray {
        val capped = ByteArrayOutputStream()
        val source = body.byteStream()
        val buffer = ByteArray(BUFFER_BYTES)
        var total: Long = 0L
        while (true) {
            val read: Int = source.read(buffer)
            if (read < 0) break
            total += read
            if (total > MANIFEST_MAX_BYTES) throw ResponseTooLarge()
            capped.write(buffer, 0, read)
        }
        return capped.toByteArray()
    }

    private fun refuse(reason: String, informational: Boolean = false): FullUpdateOutcome {
        Log.w(TAG, "update_refused:$reason")
        return FullUpdateOutcome.Refused(reason = reason, informational = informational)
    }

    private sealed interface Fetch {
        class Body(val bytes: ByteArray) : Fetch
        class Failed(val reason: String) : Fetch
    }

    private class Streamed(val bytes: Long, val sha256: String)

    private class InstallRefusal(val reason: String) : Exception(reason)

    private class ResponseTooLarge : Exception()

    companion object {
        const val MANIFEST_URL: String = "https://osratech.com/android/latest.json"
        const val SIGNATURE_URL: String = "https://osratech.com/android/latest.json.sig"
        const val MANIFEST_MAX_BYTES: Long = 64L * 1024L
        const val APK_MAX_BYTES: Long = 256L * 1024L * 1024L
        const val REASON_INSTALL_GRANT_MISSING: String = "install_grant_missing"
        const val REASON_MANIFEST_KEY_UNAVAILABLE: String = "manifest_key_unavailable"
        const val REASON_FETCH_FAILED: String = "manifest_unreachable"
        const val REASON_NETWORK_ERROR: String = "network_error"
        const val REASON_RESPONSE_TOO_LARGE: String = "response_too_large"
        const val REASON_DOWNLOAD_FAILED: String = "download_failed"
        const val REASON_MALFORMED_ARCHIVE: String = "malformed_archive"
        const val REASON_INSTALL_FAILED: String = "install_failed"
        const val REASON_CHECK_FAILED: String = "check_failed"

        private const val TAG = "FullUpdater"
        private const val SESSION_ENTRY = "full-update.apk"
        private const val BUFFER_BYTES = 64 * 1024
        private const val HEX_DIGITS = "0123456789abcdef"

        private fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
            for (byte in bytes) {
                append(HEX_DIGITS[(byte.toInt() shr 4) and 0x0f])
                append(HEX_DIGITS[byte.toInt() and 0x0f])
            }
        }

        private fun noRedirectClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .build()

        /**
         * The session's status callback body. It lives here, not in the receiver, so this is the only class
         * that names `PackageInstaller` (amendment row 5); `FullUpdateInstallReceiver` in the `full` source
         * set is a one-line delegator and the Full manifest is the only one that declares it.
         */
        fun onInstallStatus(context: Context, intent: Intent) {
            val status: Int = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
            when (status) {
                PackageInstaller.STATUS_SUCCESS -> Log.i(TAG, "update_install:success")
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    Log.i(TAG, "update_install:pending_user_action")
                    confirmationIntent(intent)?.let { confirm -> runCatching { context.startActivity(confirm) } }
                }
                else -> Log.w(
                    TAG,
                    "update_install:failed($status) ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}",
                )
            }
        }

        private fun confirmationIntent(intent: Intent): Intent? {
            val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            return confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }
}
