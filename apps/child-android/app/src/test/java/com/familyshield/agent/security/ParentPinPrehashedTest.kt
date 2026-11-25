package com.familyshield.agent.security

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1108 (Ahmed's R3, condition 6): a PIN set from the parent app arrives as the API-derived hash, and the phone
 * stores it only when it is exactly the value [ParentPin.hash] itself would write.
 */
class ParentPinPrehashedTest {

    /** The shared vector (`docs/test-vectors/parent-pin.tsv`), which the API's own KDF reproduces byte for byte. */
    private val vector = "pbkdf2\$120000\$AAECAwQFBgcICQoLDA0ODw==\$Zz5BjmcTJWsWodarg1ATvRcZTtRsaDM8dnrc7YvWMjo="

    @Test
    fun `accepts what this app writes and the shared vector the API reproduces`() {
        assertTrue(ParentPin.isPrehashed(ParentPin.hash("4729")))
        assertTrue(ParentPin.isPrehashed(vector))
        assertTrue("and the vector opens with its PIN", ParentPin.verify("4729", vector))
    }

    @Test
    fun `refuses every other shape`() {
        val refused = listOf(
            null,
            "",
            "4729",
            "plain:4729",
            // Another iteration count: a weaker hash must not be accepted just because it parses.
            "pbkdf2\$1000\$AAECAwQFBgcICQoLDA0ODw==\$v+4cs7lf1C6H2lW2gaHJtxZo6tqrt8lSvpspABHx26M=",
            // An 8-byte salt.
            "pbkdf2\$120000\$AAECAwQFBgc=\$Zz5BjmcTJWsWodarg1ATvRcZTtRsaDM8dnrc7YvWMjo=",
            // A 16-byte key.
            "pbkdf2\$120000\$AAECAwQFBgcICQoLDA0ODw==\$AAECAwQFBgcICQoLDA0ODw==",
            "$vector\n",
            " $vector",
            "$vector\$extra",
            vector.replace("pbkdf2", "PBKDF2"),
            vector.replace("Zz5B", "Zz5!"),
        )
        for (value in refused) assertFalse("refused: $value", ParentPin.isPrehashed(value))
    }
}
