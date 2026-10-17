package com.familyshield.agent.vpn

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Plan 1.4: the DNS wire codec the sinkhole answers with. */
class DnsMessageTest {

    private fun query(name: String, type: Int = DnsMessage.TYPE_A, id: Int = 0x1234, rd: Boolean = true): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(id ushr 8); out.write(id and 0xff)
        out.write(if (rd) 0x01 else 0x00); out.write(0x00)
        out.write(0); out.write(1); out.write(ByteArray(6))
        out.write(DnsMessage.encodeName(name))
        out.write(type ushr 8); out.write(type and 0xff); out.write(0); out.write(1)
        return out.toByteArray()
    }

    @Test
    fun `parses the first question`() {
        val q = DnsMessage.parseQuestion(query("www.Example.com", DnsMessage.TYPE_AAAA))!!
        assertEquals(0x1234, q.id)
        assertEquals("www.Example.com", q.name)
        assertEquals(DnsMessage.TYPE_AAAA, q.type)
        assertEquals(DnsMessage.CLASS_IN, q.klass)
        assertEquals(12 + 17 + 4, q.questionEnd)
    }

    @Test
    fun `rejects responses, truncated and empty messages`() {
        val resp = query("a.example").also { it[2] = 0x81.toByte() }
        assertNull(DnsMessage.parseQuestion(resp))
        assertNull(DnsMessage.parseQuestion(ByteArray(5)))
        assertNull(DnsMessage.parseQuestion(query("a.example").copyOf(20)))
    }

    @Test
    fun `sink answer is an A record of 0_0_0_0 with the question copied and the id kept`() {
        val qb = query("blocked.example")
        val q = DnsMessage.parseQuestion(qb)!!
        val r = DnsMessage.buildSink(qb, q, ttl = 30)
        assertEquals(0x12, r[0].toInt() and 0xff); assertEquals(0x34, r[1].toInt() and 0xff)
        assertEquals(0x81, r[2].toInt() and 0xff) // QR + RD
        assertEquals(0x80, r[3].toInt() and 0xff) // RA, rcode 0
        assertEquals(1, r[7].toInt())             // ancount
        assertArrayEquals(qb.copyOfRange(12, q.questionEnd), r.copyOfRange(12, q.questionEnd))
        val addrs = DnsMessage.extractAddresses(r, DnsMessage.TYPE_A)
        assertEquals(1, addrs.size)
        assertArrayEquals(ByteArray(4), addrs[0])
        // AAAA sinks to ::
        val q6b = query("blocked.example", DnsMessage.TYPE_AAAA); val q6 = DnsMessage.parseQuestion(q6b)!!
        assertArrayEquals(ByteArray(16), DnsMessage.extractAddresses(DnsMessage.buildSink(q6b, q6), DnsMessage.TYPE_AAAA)[0])
        // other types: empty NOERROR
        val qt = query("blocked.example", DnsMessage.TYPE_HTTPS)
        assertEquals(0, DnsMessage.buildSink(qt, DnsMessage.parseQuestion(qt)!!)[7].toInt())
    }

    @Test
    fun `nxdomain carries rcode 3 and no answers`() {
        val qb = query("x.example"); val r = DnsMessage.buildNxDomain(qb, DnsMessage.parseQuestion(qb)!!)
        assertEquals(3, r[3].toInt() and 0x0f)
        assertEquals(0, r[7].toInt())
    }

    @Test
    fun `rewrite answer is CNAME plus the target addresses, readable back`() {
        val qb = query("www.google.com"); val q = DnsMessage.parseQuestion(qb)!!
        val r = DnsMessage.buildRewrite(qb, q, "forcesafesearch.google.com", listOf(byteArrayOf(216.toByte(), 239.toByte(), 38, 120)))
        assertEquals(2, r[7].toInt())
        val addrs = DnsMessage.extractAddresses(r, DnsMessage.TYPE_A)
        assertEquals(1, addrs.size)
        assertArrayEquals(byteArrayOf(216.toByte(), 239.toByte(), 38, 120), addrs[0])
        // the CNAME rdata is the encoded target
        val cnameStart = q.questionEnd + 2 + 2 + 2 + 4 + 2
        assertArrayEquals(DnsMessage.encodeName("forcesafesearch.google.com"), r.copyOfRange(cnameStart, cnameStart + 28))
    }

    @Test
    fun `encodeName round-trips through parseQuestion`() {
        val qb = query("a.b.c.example.")
        assertEquals("a.b.c.example", DnsMessage.parseQuestion(qb)!!.name)
    }
}
