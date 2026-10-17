package com.familyshield.agent.vpn

/**
 * Minimal DNS wire codec (RFC 1035) for the sinkhole: read the first question of a query and build
 * the three answers the resolver synthesises itself — an A/AAAA "sink" answer, an NXDOMAIN, and a
 * CNAME + A rewrite. Everything else is forwarded byte-for-byte, so this never needs to understand
 * EDNS, DNSSEC or compression in records it did not write. Pure Kotlin, JVM-tested.
 */
object DnsMessage {
    const val TYPE_A = 1
    const val TYPE_CNAME = 5
    const val TYPE_AAAA = 28
    const val TYPE_HTTPS = 65
    const val CLASS_IN = 1

    data class Question(val id: Int, val name: String, val type: Int, val klass: Int, val questionEnd: Int)

    /** Parses the header and the first question; null when [buf] is not a plain query with one question. */
    fun parseQuestion(buf: ByteArray, offset: Int = 0, length: Int = buf.size - offset): Question? {
        if (length < 12) return null
        val id = u16(buf, offset)
        val flags = u16(buf, offset + 2)
        if (flags and 0x8000 != 0) return null // a response, not a query
        val qdCount = u16(buf, offset + 4)
        if (qdCount < 1) return null
        var p = offset + 12
        val end = offset + length
        val labels = ArrayList<String>()
        while (true) {
            if (p >= end) return null
            val len = buf[p].toInt() and 0xff
            if (len == 0) { p++; break }
            if (len and 0xc0 != 0) return null // compression pointer in a question: not something we handle
            if (p + 1 + len > end) return null
            labels.add(String(buf, p + 1, len, Charsets.US_ASCII))
            p += 1 + len
        }
        if (p + 4 > end) return null
        val type = u16(buf, p)
        val klass = u16(buf, p + 2)
        return Question(id, labels.joinToString("."), type, klass, p + 4 - offset)
    }

    /**
     * A response that sinks the name: an A record of 0.0.0.0 (or an AAAA of ::) with a short TTL, so
     * the app sees "resolved to nowhere" rather than an error it would retry around. For any other
     * type the answer is empty NOERROR.
     */
    fun buildSink(query: ByteArray, q: Question, ttl: Int = 30): ByteArray {
        val rdata = when (q.type) {
            TYPE_A -> ByteArray(4)
            TYPE_AAAA -> ByteArray(16)
            else -> null
        }
        return buildResponse(query, q, rcode = 0, answers = if (rdata == null) emptyList() else listOf(Record(null, q.type, ttl, rdata)))
    }

    /** NXDOMAIN for the name (used for the pause-internet mode where even "nowhere" must not resolve). */
    fun buildNxDomain(query: ByteArray, q: Question): ByteArray = buildResponse(query, q, rcode = 3, answers = emptyList())

    /**
     * A rewrite answer: `qname CNAME target` followed by the target's A/AAAA records as resolved
     * upstream ([addresses], raw 4- or 16-byte values matching [q]'s type).
     */
    fun buildRewrite(query: ByteArray, q: Question, target: String, addresses: List<ByteArray>, ttl: Int = 60): ByteArray {
        val answers = ArrayList<Record>()
        answers.add(Record(null, TYPE_CNAME, ttl, encodeName(target)))
        val targetName = encodeName(target)
        for (a in addresses) answers.add(Record(targetName, q.type, ttl, a))
        return buildResponse(query, q, rcode = 0, answers = answers)
    }

    /** [owner] null = the question name (written as a pointer to offset 12). */
    class Record(val owner: ByteArray?, val type: Int, val ttl: Int, val rdata: ByteArray)

    fun buildResponse(query: ByteArray, q: Question, rcode: Int, answers: List<Record>): ByteArray {
        val out = java.io.ByteArrayOutputStream(q.questionEnd + 64)
        // header: id, flags (QR=1, RD copied, RA=1, rcode), qd=1, an=n, ns=0, ar=0
        val rd = u16(query, 2) and 0x0100
        w16(out, q.id)
        w16(out, 0x8000 or rd or 0x0080 or (rcode and 0xf))
        w16(out, 1); w16(out, answers.size); w16(out, 0); w16(out, 0)
        out.write(query, 12, q.questionEnd - 12) // the question, verbatim
        for (r in answers) {
            if (r.owner == null) { out.write(0xc0); out.write(12) } else out.write(r.owner)
            w16(out, r.type); w16(out, CLASS_IN)
            w16(out, (r.ttl ushr 16) and 0xffff); w16(out, r.ttl and 0xffff)
            w16(out, r.rdata.size); out.write(r.rdata)
        }
        return out.toByteArray()
    }

    /** Reads the A/AAAA rdata values of [type] from a response (used to copy the rewrite target's addresses). */
    fun extractAddresses(response: ByteArray, type: Int): List<ByteArray> {
        if (response.size < 12) return emptyList()
        val qd = u16(response, 4); val an = u16(response, 6)
        var p = 12
        repeat(qd) { p = skipName(response, p); if (p < 0) return emptyList(); p += 4 }
        val out = ArrayList<ByteArray>()
        repeat(an) {
            p = skipName(response, p); if (p < 0 || p + 10 > response.size) return out
            val t = u16(response, p); val len = u16(response, p + 8); p += 10
            if (p + len > response.size) return out
            if (t == type && (len == 4 || len == 16)) out.add(response.copyOfRange(p, p + len))
            p += len
        }
        return out
    }

    private fun skipName(b: ByteArray, start: Int): Int {
        var p = start
        while (p < b.size) {
            val len = b[p].toInt() and 0xff
            if (len == 0) return p + 1
            if (len and 0xc0 == 0xc0) return p + 2
            p += 1 + len
        }
        return -1
    }

    fun encodeName(name: String): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (label in name.trimEnd('.').split('.')) {
            if (label.isEmpty()) continue
            val bytes = label.toByteArray(Charsets.US_ASCII)
            out.write(bytes.size.coerceAtMost(63)); out.write(bytes, 0, bytes.size.coerceAtMost(63))
        }
        out.write(0)
        return out.toByteArray()
    }

    private fun u16(b: ByteArray, o: Int): Int = ((b[o].toInt() and 0xff) shl 8) or (b[o + 1].toInt() and 0xff)
    private fun w16(out: java.io.ByteArrayOutputStream, v: Int) { out.write((v ushr 8) and 0xff); out.write(v and 0xff) }
}
