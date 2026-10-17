package com.familyshield.agent.vpn

/**
 * Just enough IPv4/IPv6 + UDP to pull a DNS query out of a TUN packet and push the answer back
 * (plan 1.4). Anything that is not UDP to port 53 is "other traffic" — forwarded nowhere in
 * DNS-only mode (the route table never sends it here) and dropped in pause mode. Pure Kotlin so the
 * header arithmetic and the checksums are unit-tested on the JVM.
 */
object IpPacket {
    const val PROTO_UDP = 17
    const val DNS_PORT = 53

    data class Udp(
        val version: Int,
        val src: ByteArray, val dst: ByteArray,
        val srcPort: Int, val dstPort: Int,
        /** Offset of the UDP payload inside the original buffer and its length. */
        val payloadOffset: Int, val payloadLength: Int,
    )

    /** Parses a TUN packet as IPv4/IPv6 + UDP; null for anything else (TCP, ICMP, fragments, truncated). */
    fun parseUdp(buf: ByteArray, length: Int): Udp? {
        if (length < 20) return null
        val version = (buf[0].toInt() and 0xf0) ushr 4
        return when (version) {
            4 -> {
                val ihl = (buf[0].toInt() and 0x0f) * 4
                if (ihl < 20 || length < ihl + 8) return null
                if (buf[9].toInt() and 0xff != PROTO_UDP) return null
                val flagsFrag = u16(buf, 6)
                if (flagsFrag and 0x3fff != 0) return null // fragment: not ours
                val udpLen = u16(buf, ihl + 4)
                if (udpLen < 8 || ihl + udpLen > length) return null
                Udp(4, buf.copyOfRange(12, 16), buf.copyOfRange(16, 20), u16(buf, ihl), u16(buf, ihl + 2), ihl + 8, udpLen - 8)
            }
            6 -> {
                if (length < 48) return null
                if (buf[6].toInt() and 0xff != PROTO_UDP) return null // no extension-header walking: plain UDP only
                val udpLen = u16(buf, 44)
                if (udpLen < 8 || 40 + udpLen > length) return null
                Udp(6, buf.copyOfRange(8, 24), buf.copyOfRange(24, 40), u16(buf, 40), u16(buf, 42), 48, udpLen - 8)
            }
            else -> null
        }
    }

    /** Builds the reply packet for [req] (addresses and ports swapped) carrying [payload]. */
    fun buildUdpReply(req: Udp, payload: ByteArray): ByteArray = when (req.version) {
        4 -> buildIpv4Udp(src = req.dst, dst = req.src, srcPort = req.dstPort, dstPort = req.srcPort, payload = payload)
        else -> buildIpv6Udp(src = req.dst, dst = req.src, srcPort = req.dstPort, dstPort = req.srcPort, payload = payload)
    }

    fun buildIpv4Udp(src: ByteArray, dst: ByteArray, srcPort: Int, dstPort: Int, payload: ByteArray, ttl: Int = 64): ByteArray {
        val total = 20 + 8 + payload.size
        val b = ByteArray(total)
        b[0] = 0x45; b[1] = 0
        w16(b, 2, total); w16(b, 4, 0); w16(b, 6, 0x4000) // DF
        b[8] = ttl.toByte(); b[9] = PROTO_UDP.toByte()
        System.arraycopy(src, 0, b, 12, 4); System.arraycopy(dst, 0, b, 16, 4)
        w16(b, 10, checksum(b, 0, 20))
        w16(b, 20, srcPort); w16(b, 22, dstPort); w16(b, 24, 8 + payload.size); w16(b, 26, 0)
        System.arraycopy(payload, 0, b, 28, payload.size)
        w16(b, 26, udpChecksum(src, dst, b, 20, 8 + payload.size, PROTO_UDP))
        return b
    }

    fun buildIpv6Udp(src: ByteArray, dst: ByteArray, srcPort: Int, dstPort: Int, payload: ByteArray, hops: Int = 64): ByteArray {
        val udpLen = 8 + payload.size
        val b = ByteArray(40 + udpLen)
        b[0] = 0x60
        w16(b, 4, udpLen); b[6] = PROTO_UDP.toByte(); b[7] = hops.toByte()
        System.arraycopy(src, 0, b, 8, 16); System.arraycopy(dst, 0, b, 24, 16)
        w16(b, 40, srcPort); w16(b, 42, dstPort); w16(b, 44, udpLen); w16(b, 46, 0)
        System.arraycopy(payload, 0, b, 48, payload.size)
        w16(b, 46, udpChecksum(src, dst, b, 40, udpLen, PROTO_UDP))
        return b
    }

    /** RFC 1071 one's-complement checksum over [len] bytes at [off]. */
    fun checksum(b: ByteArray, off: Int, len: Int): Int = fold(sum(b, off, len))

    /** UDP checksum with the IPv4/IPv6 pseudo-header; 0xFFFF when the computed value is zero (RFC 768). */
    fun udpChecksum(src: ByteArray, dst: ByteArray, b: ByteArray, off: Int, len: Int, proto: Int): Int {
        var s = sum(src, 0, src.size) + sum(dst, 0, dst.size)
        s += proto
        s += len
        s += sum(b, off, len)
        val c = fold(s)
        return if (c == 0) 0xffff else c
    }

    private fun sum(b: ByteArray, off: Int, len: Int): Long {
        var s = 0L
        var i = off
        val end = off + len
        while (i + 1 < end) { s += u16(b, i); i += 2 }
        if (i < end) s += (b[i].toInt() and 0xff) shl 8
        return s
    }

    private fun fold(sum: Long): Int {
        var s = sum
        while (s ushr 16 != 0L) s = (s and 0xffff) + (s ushr 16)
        return (s.inv() and 0xffff).toInt()
    }

    fun u16(b: ByteArray, o: Int): Int = ((b[o].toInt() and 0xff) shl 8) or (b[o + 1].toInt() and 0xff)
    private fun w16(b: ByteArray, o: Int, v: Int) { b[o] = ((v ushr 8) and 0xff).toByte(); b[o + 1] = (v and 0xff).toByte() }
}
