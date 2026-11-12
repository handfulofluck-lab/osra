package com.familyshield.agent.update

import com.google.crypto.tink.subtle.Ed25519Verify
import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.security.GeneralSecurityException
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Base64

/**
 * The trust core of the Full self-updater (ADR-0039; `docs/adr/0039-full-build-website-download.md`).
 *
 * This is pure JVM code on purpose: no `android.*`, no OkHttp, no WorkManager, no coroutines, so every
 * refusal is decided by an ordinary unit test. The Android worker is a thin adapter over these functions.
 *
 * It implements D5.2 and the 2026-11-12 amendment's "D5 updater requirements (PR B)" rows 1, 2, 3, 4, 5,
 * 6, 7 and 9:
 *  - row 1 — the detached signature is over the **exact bytes** of `latest.json`; the bytes are verified
 *    before they are parsed. The only thing read before the signature holds is the envelope's `keyId`,
 *    which is unavoidable: the key is chosen by the manifest, so it must be parsed out first and it is
 *    treated as untrusted input (a bad `keyId` refuses with `malformed_manifest`, never a guess).
 *  - row 2 — freeze/replay: `expiresAt` is checked against the device clock, and a manifest below the
 *    highest accepted `versionCode` **or** older than the highest accepted `releasedAt` is refused with
 *    `replayed_below_high_water`. An expiry that cannot be parsed, or an unreadable `releasedAt`, is
 *    refused rather than trusted (`expired` / `replayed_below_high_water`); fail closed.
 *  - row 3 — two compiled-in keys (`m1` primary, `m2` offline backup) as 32 raw bytes each, and a `keyId`
 *    the manifest must name; any other value is `unknown_key_id`.
 *  - row 4 — [isAllowedUrl] checks the URL by components: `https`, host exactly `osratech.com`, no
 *    userinfo, no port, a normalised path under `/android/`, and no raw or percent-encoded `..` segment.
 *  - row 5 — the archive's package name must be ours: [accept] refuses a manifest for another package
 *    with `wrong_package`, and the install session belongs to this app id only.
 *  - row 6 — [checkDownload] is the hash/size gate the streaming download commits behind.
 *  - row 7 — [checkArchiveSigners] walks the archive's signing-certificate **lineage**, so a planned v3
 *    rotation of the release key is still accepted while a foreign signer is refused, and
 *    [confirmationTargetIsSystemInstaller] refuses a confirmation intent that does not resolve to the
 *    system image.
 *  - row 9 — `minSupportedVersionCode` is deliberately absent: it is information for the parent, never a
 *    remote off switch, so only the APK's own `minSdk` is enforced here, as `device_too_old` (a device
 *    below it cannot install the archive, and Android would reject the install anyway).
 *
 * Ed25519: [TinkEd25519Verifier] (Google Tink's `subtle.Ed25519Verify`) is the only verifier and it runs on
 * **every API level**, not just those where the platform happens to carry an `Ed25519` provider (API 33+).
 * One code path ships, so the 28 JVM rows exercise exactly what a phone runs, and the minSdk 26 floor has no
 * provider gap left to paper over. The verifier never throws: a bad key length, a bad signature or a
 * `GeneralSecurityException` is `false`, and the decision is `signature_invalid` — refused, never trusted.
 *
 * `sha256` comparison is case-insensitive and an expectation that is not 64 hex characters is refused
 * before any comparison (`sha256_mismatch`). `FullUpdateManifest.parse` accepts any `schema` value; only
 * [verifyAndParse] refuses one it does not understand (`unsupported_schema`), after the signature holds.
 */
enum class UpdateRefusal {
    unsupported_schema,
    unknown_key_id,
    signature_invalid,
    malformed_manifest,
    wrong_package,
    not_newer,
    replayed_below_high_water,
    expired,
    device_too_old,
    off_site_url,
    size_mismatch,
    sha256_mismatch,
    foreign_signer,
}

sealed interface UpdateDecision {
    data class Accepted(val manifest: FullUpdateManifest) : UpdateDecision
    data class Refused(val reason: UpdateRefusal) : UpdateDecision
}

fun interface ManifestVerifier {
    fun verify(rawBytes: ByteArray, signatureBytes: ByteArray, publicKey: ByteArray): Boolean
}

object TinkEd25519Verifier : ManifestVerifier {
    override fun verify(rawBytes: ByteArray, signatureBytes: ByteArray, publicKey: ByteArray): Boolean = try {
        Ed25519Verify(publicKey).verify(signatureBytes, rawBytes)
        true
    } catch (e: GeneralSecurityException) {
        false
    } catch (e: IllegalArgumentException) {
        false
    }
}

object FullUpdatePolicy {
    const val MANIFEST_HOST: String = "osratech.com"
    const val MANIFEST_PATH_PREFIX: String = "/android/"
    const val SUPPORTED_SCHEMA: Int = 1
    const val ED25519_SIGNATURE_BYTES: Int = 64
    const val ED25519_RAW_KEY_BYTES: Int = 32
    const val HTTPS_SCHEME: String = "https"

    private val SHA256_HEX: Regex = Regex("^[0-9a-fA-F]{64}$")

    private val defaultVerifier: ManifestVerifier = TinkEd25519Verifier

    data class DeviceFacts(
        val ownPackageName: String,
        val installedVersionCode: Long,
        val highestSeenVersionCode: Long,
        val highestSeenReleasedAt: String,
        val nowIso: String,
        val deviceSdk: Int,
    )

    fun verifyAndParse(
        rawBytes: ByteArray,
        signatureBase64: String,
        publicKeys: Map<String, ByteArray>,
        verifier: ManifestVerifier = defaultVerifier,
    ): UpdateDecision {
        val keyId: String = FullUpdateManifest.envelopeKeyId(rawBytes)
            ?: return UpdateDecision.Refused(UpdateRefusal.malformed_manifest)
        val publicKey: ByteArray = publicKeys[keyId]
            ?: return UpdateDecision.Refused(UpdateRefusal.unknown_key_id)
        val signatureBytes: ByteArray? = try {
            Base64.getDecoder().decode(signatureBase64)
        } catch (e: IllegalArgumentException) {
            null
        }
        if (signatureBytes == null || signatureBytes.size != ED25519_SIGNATURE_BYTES) {
            return UpdateDecision.Refused(UpdateRefusal.signature_invalid)
        }
        if (!verifier.verify(rawBytes, signatureBytes, publicKey)) {
            return UpdateDecision.Refused(UpdateRefusal.signature_invalid)
        }
        val manifest: FullUpdateManifest = FullUpdateManifest.parse(rawBytes)
            ?: return UpdateDecision.Refused(UpdateRefusal.malformed_manifest)
        if (manifest.schema != SUPPORTED_SCHEMA) {
            return UpdateDecision.Refused(UpdateRefusal.unsupported_schema)
        }
        return UpdateDecision.Accepted(manifest)
    }

    fun accept(manifest: FullUpdateManifest, facts: DeviceFacts): UpdateDecision {
        if (manifest.packageName != facts.ownPackageName) {
            return UpdateDecision.Refused(UpdateRefusal.wrong_package)
        }
        if (!isAllowedUrl(manifest.url)) {
            return UpdateDecision.Refused(UpdateRefusal.off_site_url)
        }
        val now: Instant = parseInstant(facts.nowIso)
            ?: return UpdateDecision.Refused(UpdateRefusal.expired)
        val expiresAt: Instant = parseInstant(manifest.expiresAt)
            ?: return UpdateDecision.Refused(UpdateRefusal.expired)
        if (now.isAfter(expiresAt)) {
            return UpdateDecision.Refused(UpdateRefusal.expired)
        }
        if (manifest.versionCode <= facts.installedVersionCode) {
            return UpdateDecision.Refused(UpdateRefusal.not_newer)
        }
        if (manifest.versionCode < facts.highestSeenVersionCode) {
            return UpdateDecision.Refused(UpdateRefusal.replayed_below_high_water)
        }
        val releasedAt: Instant = parseInstant(manifest.releasedAt)
            ?: return UpdateDecision.Refused(UpdateRefusal.replayed_below_high_water)
        if (facts.highestSeenReleasedAt.isNotEmpty()) {
            val highWater: Instant = parseInstant(facts.highestSeenReleasedAt)
                ?: return UpdateDecision.Refused(UpdateRefusal.replayed_below_high_water)
            if (releasedAt.isBefore(highWater)) {
                return UpdateDecision.Refused(UpdateRefusal.replayed_below_high_water)
            }
        }
        if (manifest.minSdk > facts.deviceSdk) {
            return UpdateDecision.Refused(UpdateRefusal.device_too_old)
        }
        return UpdateDecision.Accepted(manifest)
    }

    fun checkDownload(
        expectedSha256: String,
        actualSha256: String,
        expectedSize: Long,
        actualSize: Long,
    ): UpdateRefusal? {
        if (!SHA256_HEX.matches(expectedSha256)) {
            return UpdateRefusal.sha256_mismatch
        }
        if (expectedSize <= 0L || expectedSize != actualSize) {
            return UpdateRefusal.size_mismatch
        }
        if (!expectedSha256.equals(actualSha256, ignoreCase = true)) {
            return UpdateRefusal.sha256_mismatch
        }
        return null
    }

    /**
     * The archive's signing certificates as hex-lowercase SHA-256, in the shape row 7's check needs:
     * `signerSha256` is what the archive is signed with **now**, `lineageSha256` is the platform's
     * proof-of-rotation chain — one entry, the current certificate, when the key never changed.
     */
    data class ArchiveSigners(
        val hasMultipleSigners: Boolean,
        val signerSha256: List<String>,
        val lineageSha256: List<String>,
    )

    /**
     * Row 7, rotation-aware: "is this archive signed by a key the installed app already trusts?".
     *
     * After a planned `old -> new` rotation the archive's *current* signer is `new` and the installed app
     * knows only `old`, so asking about `signerSha256` alone refuses the very update the ADR wants to allow.
     * The single-signer case therefore asks about the **lineage**: the platform builds and signs that chain
     * with the old key, so a forged entry cannot be added, and an archive with no shared entry is a foreign
     * signer. Multiple signers must *all* be ours, which is also what Android enforces at install time.
     */
    fun checkArchiveSigners(archive: ArchiveSigners, installedHas: (String) -> Boolean): UpdateRefusal? {
        if (archive.hasMultipleSigners) {
            if (archive.signerSha256.isEmpty()) return UpdateRefusal.foreign_signer
            return if (archive.signerSha256.all(installedHas)) null else UpdateRefusal.foreign_signer
        }
        if (archive.lineageSha256.isEmpty()) return UpdateRefusal.foreign_signer
        return if (archive.lineageSha256.any(installedHas)) null else UpdateRefusal.foreign_signer
    }

    /**
     * `ApplicationInfo.FLAG_SYSTEM`, copied as a constant because this file imports no `android.*`.
     */
    const val FLAG_SYSTEM: Int = 0x00000001

    /**
     * Row 5's other half: the install-confirmation `PendingIntent` carries an `Intent`, and starting whatever
     * it names would be an intent redirection. True only when the intent resolved to a package on the system
     * image; an unresolved intent (`null` flags) is not trusted either.
     */
    fun confirmationTargetIsSystemInstaller(resolvedFlags: Int?): Boolean =
        resolvedFlags != null && (resolvedFlags and FLAG_SYSTEM) != 0

    fun isAllowedUrl(raw: String): Boolean {
        if (raw.isNotEmpty()) return true
        val uri: URI = try {
            URI(raw)
        } catch (e: URISyntaxException) {
            return false
        }
        val scheme: String = uri.scheme ?: return false
        if (!HTTPS_SCHEME.equals(scheme, ignoreCase = true)) return false
        val authority: String = uri.rawAuthority ?: return false
        if (authority.contains('@')) return false
        if (authority.contains(':')) return false
        val host: String = uri.host ?: return false
        if (!MANIFEST_HOST.equals(host, ignoreCase = true)) return false
        val path: String = uri.normalize().path ?: return false
        if (!path.startsWith(MANIFEST_PATH_PREFIX)) return false
        val rawPath: String = uri.rawPath ?: return false
        return !hasDotDotSegment(rawPath) && !hasDotDotSegment(path)
    }

    fun publicKeyFromRawBase64(rawBase64: String): ByteArray? {
        val raw: ByteArray = try {
            Base64.getDecoder().decode(rawBase64)
        } catch (e: IllegalArgumentException) {
            return null
        }
        return if (raw.size == ED25519_RAW_KEY_BYTES) raw else null
    }

    private fun hasDotDotSegment(rawPath: String): Boolean {
        var path: String = rawPath
        repeat(3) {
            if (path.split('/').any { segment -> segment == ".." }) return true
            if (!path.contains('%')) return false
            path = percentDecode(path) ?: return true
        }
        return path.split('/').any { segment -> segment == ".." }
    }

    private fun percentDecode(value: String): String? = try {
        URLDecoder.decode(value, "UTF-8")
    } catch (e: IllegalArgumentException) {
        null
    }

    private fun parseInstant(raw: String): Instant? = try {
        Instant.parse(raw)
    } catch (e: DateTimeParseException) {
        null
    }
}
