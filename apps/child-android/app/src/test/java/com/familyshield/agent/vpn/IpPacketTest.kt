package com.familyshield.agent.vpn

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Plan 1.4: IPv4/IPv6 + UDP framing for the TUN. */
class IpPacketTest {
    private val a = byteArrayOf(10, 111, 222.toByte(), 1)
    private val b = byteArrayOf(10, 111, 222.toByte(), 2)

    @Test
    fun `ipv4 udp builds, parses back and checksums verify`() {
        val payload = "hello".toByteArray()
        val p = IpPacket.buildIpv4Udp(a, b, 40000, 53, payload)
        assertEquals(20 + 8 + 5, p.size)
        // header checksum verifies to zero over the header
        assertEquals(0, IpPacket.checksum(p, 0, 20))
        // UDP checksum with pseudo-header verifies to zero
        assertEquals(0, IpPacket.udpChecksum(a, b, p, 20, 13, IpPacket.PROTO_UDP).let { if (it == 0xffff) 0 else it })
        val u = IpPacket.parseUdp(p, p.size)!!
        assertEquals(4, u.version); assertArrayEquals(a, u.src); assertArrayEquals(b, u.dst)
        assertEquals(40000, u.srcPort); assertEquals(53, u.dstPort)
        assertArrayEquals(payload, p.copyOfRange(u.payloadOffset, u.payloadOffset + u.payloadLength))
    }

    @Test
    fun `reply swaps addresses and ports`() {
        val req = IpPacket.parseUdp(IpPacket.buildIpv4Udp(a, b, 40000, 53, byteArrayOf(1)), 29)!!
        val r = IpPacket.parseUdp(IpPacket.buildUdpReply(req, byteArrayOf(2, 3)), 30)!!
        assertArrayEquals(b, r.src); assertArrayEquals(a, r.dst)
        assertEquals(53, r.srcPort); assertEquals(40000, r.dstPort)
        assertEquals(2, r.payloadLength)
    }

    @Test
    fun `ipv6 udp builds and parses back`() {
        val s6 = ByteArray(16).also { it[0] = 0xfd.toByte(); it[15] = 1 }
        val d6 = ByteArray(16).also { it[0] = 0xfd.toByte(); it[15] = 2 }
        val p = IpPacket.buildIpv6Udp(s6, d6, 5000, 53, byteArrayOf(9, 9, 9))
        assertEquals(40 + 8 + 3, p.size)
        val u = IpPacket.parseUdp(p, p.size)!!
        assertEquals(6, u.version); assertArrayEquals(s6, u.src); assertArrayEquals(d6, u.dst)
        assertEquals(5000, u.srcPort); assertEquals(53, u.dstPort); assertEquals(3, u.payloadLength)
        assertEquals(0, IpPacket.udpChecksum(s6, d6, p, 40, 11, IpPacket.PROTO_UDP).let { if (it == 0xffff) 0 else it })
    }

    @Test
    fun `non-udp, fragments and junk are not parsed`() {
        val tcp = IpPacket.buildIpv4Udp(a, b, 1, 2, byteArrayOf()).also { it[9] = 6 }
        assertNull(IpPacket.parseUdp(tcp, tcp.size))
        val frag = IpPacket.buildIpv4Udp(a, b, 1, 2, byteArrayOf()).also { it[6] = 0x20; it[7] = 0x01 }
        assertNull(IpPacket.parseUdp(frag, frag.size))
        assertNull(IpPacket.parseUdp(ByteArray(10), 10))
        assertNull(IpPacket.parseUdp(ByteArray(40).also { it[0] = 0x50 }, 40))
        val short = IpPacket.buildIpv4Udp(a, b, 1, 2, byteArrayOf(1, 2, 3))
        assertNull(IpPacket.parseUdp(short, short.size - 2))
    }

    @Test
    fun `checksum of the RFC 1071 example`() {
        // 0x0001 0xf203 0xf4f5 0xf6f7 → sum 0xddf2 → complement 0x220d
        val b = byteArrayOf(0x00, 0x01, 0xf2.toByte(), 0x03, 0xf4.toByte(), 0xf5.toByte(), 0xf6.toByte(), 0xf7.toByte())
        assertEquals(0x220d, IpPacket.checksum(b, 0, 8))
    }
}
