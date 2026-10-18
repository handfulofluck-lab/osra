package com.familyshield.agent.manifest

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/**
 * The manifest AGP actually produced for one variant
 * (`app/build/intermediates/merged_manifests/<flavor>Debug/…/AndroidManifest.xml`), parsed into the
 * handful of facts ADR-0021 is about.
 *
 * Why the merged file and not the sources under `app/src/<flavor>/`: manifest merging is where a dependency's
 * declarations arrive. A library that ships `READ_SMS` or a notification-listener service puts it in
 * this file and in no file we authored, which is why `FlavorManifestTest`'s source-text assertions
 * cannot see it and this class exists (finding F2, #101 review — `docs/TESTING.md` §6).
 *
 * The merged manifest is fully expanded: component names are absolute (`com.familyshield.agent.…`),
 * library components are present, and every merged `uses-permission*` element is listed once at the top.
 */
class MergedManifest private constructor(
    val includedPermissions: Set<String>,
    val applicationMetaData: Map<String, String>,
    val queries: List<QueryIntent>,
    val components: List<Component>,
) {
    data class QueryIntent(val actions: Set<String>, val categories: Set<String>)

    data class Component(
        val tag: String,
        val name: String,
        val permission: String?,
        val intentActions: Set<String>,
    )

    /** Every action any component's `<intent-filter>` declares. */
    val componentIntentActions: Set<String> = components.flatMapTo(mutableSetOf()) { it.intentActions }

    fun hasQuery(action: String, category: String? = null): Boolean =
        queries.any { action in it.actions && (category == null || category in it.categories) }

    companion object {
        private val COMPONENT_TAGS = listOf("activity", "activity-alias", "service", "receiver", "provider")

        private val PERMISSION_TAGS = listOf("uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m")

        fun read(file: File): MergedManifest = parse(file.readText(Charsets.UTF_8))

        fun parse(xml: String): MergedManifest {
            val factory = DocumentBuilderFactory.newInstance().apply {
                isNamespaceAware = false
                // A test never needs a DTD, and refusing one keeps the parser from resolving entities.
                setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
            }
            val root = factory.newDocumentBuilder()
                .parse(xml.byteInputStream(Charsets.UTF_8))
                .documentElement
            require(root.tagName == "manifest") { "not an AndroidManifest: <${root.tagName}>" }

            val application = root.kids("application").firstOrNull()
            val components = application?.let { app ->
                COMPONENT_TAGS.flatMap { tag ->
                    app.kids(tag).map { element ->
                        Component(
                            tag = tag,
                            name = element.attr("android:name") ?: "",
                            permission = element.attr("android:permission"),
                            intentActions = element.kids("intent-filter")
                                .flatMap { filter -> filter.kids("action") }
                                .mapNotNull { action -> action.attr("android:name") }
                                .toSet(),
                        )
                    }
                }
            } ?: emptyList()

            return MergedManifest(
                // `uses-permission-sdk-23`/`-sdk-m` are merged unchanged too; a library could declare a
                // forbidden permission only for newer platforms, so read every uses-permission form.
                includedPermissions = PERMISSION_TAGS
                    .flatMap { tag -> root.kids(tag) }
                    .mapNotNull { it.attr("android:name") }
                    .toSet(),
                applicationMetaData = application?.kids("meta-data")
                    ?.map { it.attr("android:name") to (it.attr("android:value") ?: "") }
                    ?.filter { it.first != null }
                    ?.associate { it.first!! to it.second }
                    ?: emptyMap(),
                queries = root.kids("queries").flatMap { queries ->
                    queries.kids("intent").map { intent ->
                        QueryIntent(
                            actions = intent.kids("action").mapNotNull { it.attr("android:name") }.toSet(),
                            categories = intent.kids("category").mapNotNull { it.attr("android:name") }.toSet(),
                        )
                    }
                },
                components = components,
            )
        }
    }
}

private fun Element.kids(tag: String): List<Element> {
    val nodes = childNodes
    val matches = ArrayList<Element>(nodes.length)
    for (index in 0 until nodes.length) {
        val node = nodes.item(index)
        if (node is Element && node.tagName == tag) matches += node
    }
    return matches
}

private fun Element.attr(name: String): String? = getAttributeNode(name)?.value
