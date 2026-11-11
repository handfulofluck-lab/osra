package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR-0036 (#372): the parent-PIN cases in `docs/test-vectors/parent-pin.tsv` are shared with the iOS suite
 * (`ParentPinTests.swift`), so both platforms refuse the same PINs with the same words and read the same stored
 * hashes. A row that fails here, or on iOS, means the two platforms have drifted apart.
 *
 * Mutants: drop the weak-PIN list, change a refusal message, or accept a malformed hash → a named row fails.
 */
class ParentPinSharedCasesTest {

    private data class Row(val kind: String, val cells: List<String>)

    private val rows: List<Row> = sourceFile("docs/test-vectors/parent-pin.tsv").lines()
        .filter { it.isNotBlank() && !it.startsWith("#") }
        .map { line -> line.split('\t').map { if (it == "<empty>") "" else it }.let { Row(it[0], it.drop(1)) } }

    @Test
    fun `the shared table has both kinds of row`() {
        assertTrue(rows.count { it.kind == "validate" } >= 10)
        assertTrue(rows.count { it.kind == "verify" } >= 8)
    }

    @Test
    fun `validation matches every shared row`() {
        for (row in rows.filter { it.kind == "validate" }) {
            val (pin, expected) = row.cells
            assertEquals("validate '$pin'", if (expected == "ok") null else expected, ParentPin.validationError(pin))
        }
    }

    @Test
    fun `verification matches every shared row`() {
        for (row in rows.filter { it.kind == "verify" }) {
            val (pin, stored, expected) = row.cells
            assertEquals("verify '$pin' against '$stored'", expected == "true", ParentPin.verify(pin, stored.ifEmpty { null }))
        }
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
