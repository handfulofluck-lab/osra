package com.familyshield.agent.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.security.Signature
import java.util.Base64

class FullUpdatePolicyTest {

    private val manifestKeys: KeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()

    private val publicKeys: Map<String, ByteArray> = mapOf(PRIMARY_KEY_ID to exportPublic(manifestKeys.public))

    @Test
    fun schemaIsNotOneIsRefused() {
        assertEquals(UpdateRefusal.unsupported_schema, verifyRefusal(manifestJson(schema = 2)))
        assertNull(verifyRefusal(manifestJson(schema = 1)))
    }

    @Test
    fun unknownKeyIdIsRefused() {
        assertEquals(UpdateRefusal.unknown_key_id, verifyRefusal(manifestJson(keyId = "m9")))
        assertNull(verifyRefusal(manifestJson(keyId = PRIMARY_KEY_ID)))
    }

    @Test
    fun oneFlippedSignatureByteIsRefused() {
        val bytes: ByteArray = manifestJson()
        assertNull(verifyRefusal(bytes))
        val signature: ByteArray = Base64.getDecoder().decode(sign(bytes))
        signature[signature.lastIndex] = (signature.last().toInt() xor 0x01).toByte()
        assertEquals(
            UpdateRefusal.signature_invalid,
            verifyRefusal(bytes, Base64.getEncoder().encodeToString(signature)),
        )
    }

    @Test
    fun manifestOfAnotherAppIsRefused() {
        assertEquals(UpdateRefusal.wrong_package, acceptRefusal(manifestJson(packageName = "com.osratech.child")))
    }

    @Test
    fun equalVersionCodeIsRefused() {
        assertEquals(UpdateRefusal.not_newer, acceptRefusal(manifestJson(versionCode = 7L)))
    }

    @Test
    fun lowerVersionCodeIsRefused() {
        assertEquals(UpdateRefusal.not_newer, acceptRefusal(manifestJson(versionCode = 6L)))
    }

    @Test
    fun versionBelowHighestSeenIsRefused() {
        assertEquals(
            UpdateRefusal.replayed_below_high_water,
            acceptRefusal(
                manifestJson(versionCode = 8L),
                goodFacts(installedVersionCode = 4L, highestSeenVersionCode = 9L),
            ),
        )
    }

    @Test
    fun olderReleasedAtThanHighestSeenIsRefused() {
        assertEquals(
            UpdateRefusal.replayed_below_high_water,
            acceptRefusal(manifestJson(releasedAt = "2026-11-01T10:00:00Z")),
        )
        assertNull(acceptRefusal(manifestJson(releasedAt = "2026-11-20T10:00:00Z")))
    }

    @Test
    fun expiredManifestIsRefused() {
        assertEquals(
            UpdateRefusal.expired,
            acceptRefusal(manifestJson(), goodFacts(nowIso = "2027-01-01T00:00:01Z")),
        )
        assertNull(acceptRefusal(manifestJson(), goodFacts(nowIso = "2027-01-01T00:00:00Z")))
    }

    @Test
    fun httpUrlIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "http://osratech.com/android/osra-kids-full-0.4.0-8.apk")),
        )
    }

    @Test
    fun otherHostIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://osratech.example/android/osra-kids-full-0.4.0-8.apk")),
        )
    }

    @Test
    fun subdomainIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://cdn.osratech.com/android/osra-kids-full-0.4.0-8.apk")),
        )
    }

    @Test
    fun userinfoIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://m1@osratech.com/android/osra-kids-full-0.4.0-8.apk")),
        )
    }

    @Test
    fun portIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://osratech.com:8443/android/osra-kids-full-0.4.0-8.apk")),
        )
    }

    @Test
    fun pathOutsideAndroidIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://osratech.com/releases/latest.json")),
        )
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://osratech.com/android/../latest.json")),
        )
    }

    @Test
    fun encodedDotDotIsRefused() {
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://osratech.com/android/%2e%2e/%2e%2e/api/secret")),
        )
        assertEquals(
            UpdateRefusal.off_site_url,
            acceptRefusal(manifestJson(url = "https://osratech.com/android/%2E%2E/latest.json")),
        )
    }

    @Test
    fun sizeMismatchIsRefused() {
        assertEquals(
            UpdateRefusal.size_mismatch,
            FullUpdatePolicy.checkDownload(GOOD_SHA256, GOOD_SHA256, 9123456L, 9123455L),
        )
        assertNull(FullUpdatePolicy.checkDownload(GOOD_SHA256, GOOD_SHA256, 9123456L, 9123456L))
    }

    @Test
    fun sha256MismatchIsRefused() {
        assertEquals(
            UpdateRefusal.sha256_mismatch,
            FullUpdatePolicy.checkDownload(GOOD_SHA256, OTHER_SHA256, 9123456L, 9123456L),
        )
        assertEquals(
            UpdateRefusal.sha256_mismatch,
            FullUpdatePolicy.checkDownload("not-a-digest", GOOD_SHA256, 9123456L, 9123456L),
        )
    }

    @Test
    fun uppercaseSha256IsAccepted() {
        assertNull(FullUpdatePolicy.checkDownload(GOOD_SHA256.uppercase(), GOOD_SHA256, 9123456L, 9123456L))
        assertNull(FullUpdatePolicy.checkDownload(GOOD_SHA256, GOOD_SHA256.uppercase(), 9123456L, 9123456L))
    }

    @Test
    fun sameSignerIsAccepted() {
        val archive: FullUpdatePolicy.ArchiveSigners =
            FullUpdatePolicy.ArchiveSigners(false, listOf(OLD_SIGNER), listOf(OLD_SIGNER))
        assertNull(FullUpdatePolicy.checkArchiveSigners(archive) { sha256 -> sha256 == OLD_SIGNER })
    }

    @Test
    fun rotatedSignerStillAccepted() {
        val archive: FullUpdatePolicy.ArchiveSigners =
            FullUpdatePolicy.ArchiveSigners(false, listOf(NEW_SIGNER), listOf(OLD_SIGNER, NEW_SIGNER))
        assertNull(FullUpdatePolicy.checkArchiveSigners(archive) { sha256 -> sha256 == OLD_SIGNER })
    }

    @Test
    fun foreignSignerIsRefused() {
        val archive: FullUpdatePolicy.ArchiveSigners =
            FullUpdatePolicy.ArchiveSigners(false, listOf(FOREIGN_SIGNER), listOf(FOREIGN_SIGNER))
        assertEquals(
            UpdateRefusal.foreign_signer,
            FullUpdatePolicy.checkArchiveSigners(archive) { sha256 -> sha256 == OLD_SIGNER || sha256 == NEW_SIGNER },
        )
    }

    @Test
    fun multipleSignersWithOneForeignIsRefused() {
        val archive: FullUpdatePolicy.ArchiveSigners =
            FullUpdatePolicy.ArchiveSigners(true, listOf(OLD_SIGNER, FOREIGN_SIGNER), listOf(OLD_SIGNER, FOREIGN_SIGNER))
        assertEquals(
            UpdateRefusal.foreign_signer,
            FullUpdatePolicy.checkArchiveSigners(archive) { sha256 -> sha256 == OLD_SIGNER },
        )
        assertNull(
            FullUpdatePolicy.checkArchiveSigners(
                FullUpdatePolicy.ArchiveSigners(true, listOf(OLD_SIGNER), listOf(OLD_SIGNER)),
            ) { sha256 -> sha256 == OLD_SIGNER },
        )
    }

    @Test
    fun confirmationIntentMustResolveToSystemInstaller() {
        assertTrue(FullUpdatePolicy.confirmationTargetIsSystemInstaller(FullUpdatePolicy.FLAG_SYSTEM))
        assertFalse(FullUpdatePolicy.confirmationTargetIsSystemInstaller(0))
        assertFalse(FullUpdatePolicy.confirmationTargetIsSystemInstaller(null))
    }

    @Test
    fun deviceBelowManifestMinSdkIsRefused() {
        assertEquals(
            UpdateRefusal.device_too_old,
            acceptRefusal(manifestJson(minSdk = 33), goodFacts(deviceSdk = 26)),
        )
        assertNull(acceptRefusal(manifestJson(minSdk = 26), goodFacts(deviceSdk = 26)))
    }

    @Test
    fun aGoodManifestIsAccepted() {
        val manifest: FullUpdateManifest = verifiedManifest()
        assertTrue(FullUpdatePolicy.isAllowedUrl(manifest.url))
        assertEquals(UpdateDecision.Accepted(manifest), FullUpdatePolicy.accept(manifest, goodFacts()))
        assertEquals(8L, manifest.versionCode)
        assertEquals(OWN_PACKAGE, manifest.packageName)
        assertEquals(PRIMARY_KEY_ID, manifest.keyId)
    }

    @Test
    fun aBadlySignedMalformedBodyIsRefusedAsSignatureInvalid() {
        val body: ByteArray = """{"keyId":"m1"}""".toByteArray(Charsets.UTF_8)
        assertEquals(UpdateRefusal.signature_invalid, verifyRefusal(body, sign(manifestJson())))
    }

    @Test
    fun aValidlySignedMalformedBodyIsRefusedAsMalformed() {
        val body: ByteArray = """{"keyId":"m1"}""".toByteArray(Charsets.UTF_8)
        assertEquals(UpdateRefusal.malformed_manifest, verifyRefusal(body, sign(body)))
        val broken: ByteArray = "this is not json at all".toByteArray(Charsets.UTF_8)
        assertEquals(UpdateRefusal.malformed_manifest, verifyRefusal(broken, sign(broken)))
    }

    private fun verifyRefusal(bytes: ByteArray, signatureBase64: String = sign(bytes)): UpdateRefusal? =
        when (val decision: UpdateDecision = FullUpdatePolicy.verifyAndParse(bytes, signatureBase64, publicKeys)) {
            is UpdateDecision.Accepted -> null
            is UpdateDecision.Refused -> decision.reason
        }

    private fun verifiedManifest(bytes: ByteArray = manifestJson()): FullUpdateManifest {
        val decision: UpdateDecision = FullUpdatePolicy.verifyAndParse(bytes, sign(bytes), publicKeys)
        assertTrue("the manifest must verify before accept() is exercised, got $decision", decision is UpdateDecision.Accepted)
        return (decision as UpdateDecision.Accepted).manifest
    }

    private fun acceptRefusal(
        bytes: ByteArray = manifestJson(),
        facts: FullUpdatePolicy.DeviceFacts = goodFacts(),
    ): UpdateRefusal? =
        when (val decision: UpdateDecision = FullUpdatePolicy.accept(verifiedManifest(bytes), facts)) {
            is UpdateDecision.Accepted -> null
            is UpdateDecision.Refused -> decision.reason
        }

    private fun goodFacts(
        ownPackageName: String = OWN_PACKAGE,
        installedVersionCode: Long = 7L,
        highestSeenVersionCode: Long = 7L,
        highestSeenReleasedAt: String = "2026-11-20T10:00:00Z",
        nowIso: String = "2026-12-02T00:00:00Z",
        deviceSdk: Int = 34,
    ): FullUpdatePolicy.DeviceFacts = FullUpdatePolicy.DeviceFacts(
        ownPackageName = ownPackageName,
        installedVersionCode = installedVersionCode,
        highestSeenVersionCode = highestSeenVersionCode,
        highestSeenReleasedAt = highestSeenReleasedAt,
        nowIso = nowIso,
        deviceSdk = deviceSdk,
    )

    private fun manifestJson(
        schema: Int = 1,
        packageName: String = OWN_PACKAGE,
        versionCode: Long = 8L,
        versionName: String = "0.4.0-full",
        url: String = GOOD_URL,
        sha256: String = GOOD_SHA256,
        size: Long = 9123456L,
        minSdk: Int = 26,
        releasedAt: String = "2026-12-01T10:00:00Z",
        expiresAt: String = "2027-01-01T00:00:00Z",
        keyId: String = PRIMARY_KEY_ID,
    ): ByteArray {
        val json: String = "{" +
            "\"schema\":$schema," +
            "\"packageName\":\"$packageName\"," +
            "\"versionCode\":$versionCode," +
            "\"versionName\":\"$versionName\"," +
            "\"url\":\"$url\"," +
            "\"sha256\":\"$sha256\"," +
            "\"size\":$size," +
            "\"minSdk\":$minSdk," +
            "\"releasedAt\":\"$releasedAt\"," +
            "\"expiresAt\":\"$expiresAt\"," +
            "\"keyId\":\"$keyId\"" +
            "}"
        return json.toByteArray(Charsets.UTF_8)
    }

    private fun sign(bytes: ByteArray, keyPair: KeyPair = manifestKeys): String {
        val signer: Signature = Signature.getInstance("Ed25519")
        signer.initSign(keyPair.private)
        signer.update(bytes)
        return Base64.getEncoder().encodeToString(signer.sign())
    }

    private fun exportPublic(generated: PublicKey): ByteArray {
        val spki: ByteArray = generated.encoded
        val raw: ByteArray = spki.copyOfRange(spki.size - FullUpdatePolicy.ED25519_RAW_KEY_BYTES, spki.size)
        val base64: String = Base64.getEncoder().encodeToString(raw)
        return requireNotNull(FullUpdatePolicy.publicKeyFromRawBase64(base64))
    }

    private companion object {
        const val OWN_PACKAGE: String = "com.osratech.child.full"
        const val PRIMARY_KEY_ID: String = "m1"
        const val GOOD_URL: String = "https://osratech.com/android/osra-kids-full-0.4.0-8.apk"
        const val GOOD_SHA256: String =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        const val OTHER_SHA256: String =
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        const val OLD_SIGNER: String =
            "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
        const val NEW_SIGNER: String =
            "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1"
        const val FOREIGN_SIGNER: String =
            "c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2"
    }
}
