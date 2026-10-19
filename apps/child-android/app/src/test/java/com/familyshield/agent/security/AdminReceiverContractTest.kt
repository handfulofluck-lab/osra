package com.familyshield.agent.security

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Issue #202: the device-admin component name exists in the class, the manifest and the hardware
 * scripts. A rename that lands in only some of them registers a receiver no code owns (Android boots
 * the old name, `DeviceAdminManager` asks about the new one), and on Samsung it is the difference
 * between "activates through the sheet" and a stale Knox row that says `Admin is already added`.
 *
 * This is the JVM half of the pin: the manifest's receiver must resolve to
 * [ParentalAdminReceiver.COMPONENT_CLASS], and `res/xml/device_admin.xml` must still grant exactly the
 * policies the code was reviewed with (ADR-0010). It reads the **source** manifest; the merged
 * manifests are asserted separately in `PlayMergedManifestTest` / `FullMergedManifestTest`.
 */
class AdminReceiverContractTest {

    private val receiverClass = ParentalAdminReceiver::class.java

    private val manifest by lazy { parse(source("app/src/main/AndroidManifest.xml")) }
    private val deviceAdmin by lazy { parse(source("app/src/main/res/xml/device_admin.xml")) }

    private val namespace by lazy {
        val gradle = source("app/build.gradle.kts").readText()
        Regex("namespace\\s*=\\s*\"([^\"]+)\"")
            .find(gradle)?.groupValues?.get(1)
            ?: throw AssertionError("app/build.gradle.kts declares no android namespace")
    }

    @Test
    fun `the manifest receiver is the class the code constant names`() {
        assertEquals(
            "ParentalAdminReceiver.COMPONENT_CLASS and the class must not drift",
            receiverClass.name,
            ParentalAdminReceiver.COMPONENT_CLASS,
        )

        val declared = adminReceiver().attr("android:name")
            ?: throw AssertionError("the device-admin <receiver> has no android:name")
        val expectedRelative = "." + receiverClass.name.removePrefix("$namespace.")
        assertEquals(
            "the manifest registers a device-admin receiver that is not ${receiverClass.name}. " +
                "A rename must land in the class, the constant and the manifest together (issue #202).",
            expectedRelative,
            declared,
        )
        assertEquals(
            "the relative manifest name must resolve to the class Android will instantiate",
            receiverClass.name,
            resolve(declared),
        )
    }

    @Test
    fun `the manifest receiver keeps the device-admin contract`() {
        val receiver = adminReceiver()
        assertEquals(
            "the receiver must require BIND_DEVICE_ADMIN, not merely declare it",
            "android.permission.BIND_DEVICE_ADMIN",
            receiver.attr("android:permission"),
        )
        assertEquals("android:exported", "true", receiver.attr("android:exported"))

        val meta = receiver.children("meta-data")
            .firstOrNull { it.attr("android:name") == "android.app.device_admin" }
        assertNotNull("no <meta-data android:name=\"android.app.device_admin\"> on the receiver", meta)
        assertEquals("@xml/device_admin", meta!!.attr("android:resource"))

        val actions = receiver.children("intent-filter")
            .flatMap { it.children("action") }
            .mapNotNull { it.attr("android:name") }
            .toSet()
        assertTrue(
            "the receiver must handle DEVICE_ADMIN_ENABLED, found $actions",
            "android.app.action.DEVICE_ADMIN_ENABLED" in actions,
        )
    }

    @Test
    fun `device_admin xml grants exactly the policies the code was reviewed with`() {
        assertEquals("device-admin", deviceAdmin.tagName)

        val blocks = deviceAdmin.children("uses-policies")
        assertEquals("device_admin.xml must declare one <uses-policies> block", 1, blocks.size)
        val declared = blocks.single().children().map { it.tagName }.toSet()

        // ADR-0010: force-lock is what DeviceAdminManager.lockNow() needs; watch-login is the reviewed
        // pairing of the receiver's callbacks. Equality, not containment, so a dropped or added policy
        // changes what the activation sheet grants and fails here.
        assertEquals(
            "device_admin.xml no longer matches ADR-0010's reviewed policy set",
            setOf("force-lock", "watch-login"),
            declared,
        )
    }

    private fun adminReceiver(): Element {
        val receivers = manifest.getElementsByTagName("receiver")
        for (index in 0 until receivers.length) {
            val element = receivers.item(index) as Element
            val isAdmin = element.children("meta-data")
                .any { it.attr("android:name") == "android.app.device_admin" }
            if (isAdmin) return element
        }
        throw AssertionError("no <receiver> in the manifest declares android.app.device_admin")
    }

    private fun resolve(name: String): String = if (name.startsWith(".")) namespace + name else name

    private fun source(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }

    private fun parse(file: File): Element {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = false
            // The test never needs a DTD, and refusing one keeps the parser from resolving entities.
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        }
        return factory.newDocumentBuilder().parse(file).documentElement
    }
}

private fun Element.children(tag: String): List<Element> {
    val nodes = childNodes
    val matches = ArrayList<Element>(nodes.length)
    for (index in 0 until nodes.length) {
        val node = nodes.item(index)
        if (node is Element && node.tagName == tag) matches += node
    }
    return matches
}

private fun Element.children(): List<Element> {
    val nodes = childNodes
    val matches = ArrayList<Element>(nodes.length)
    for (index in 0 until nodes.length) {
        val node = nodes.item(index)
        if (node is Element) matches += node
    }
    return matches
}

private fun Element.attr(name: String): String? = getAttributeNode(name)?.value
