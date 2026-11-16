package com.familyshield.agent.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.familyshield.agent.R
import com.familyshield.agent.data.BlocklistStore
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.security.TamperAlertWorker
import com.familyshield.agent.setup.PairingActivity
import dagger.hilt.android.AndroidEntryPoint
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The local DNS sinkhole (plan item 1.4, ADR-0015). A [VpnService] whose tunnel carries only the
 * device's DNS traffic in normal operation: the tunnel's resolver address is routed into the TUN,
 * every other destination stays on the real network, so the agent never sees or proxies the
 * child's payload traffic. Each query is answered by [DnsFilterPolicy] — forwarded upstream through
 * a protected socket, sunk to 0.0.0.0, or rewritten to the search engine's enforcement host.
 *
 * In **pause-internet** mode the tunnel takes the default route instead and everything that lands
 * in it is dropped on the floor, which is what "the internet is paused" has to mean on a phone
 * without a device owner; the parent's always-allowed apps, the agent itself and — in this mode only —
 * Google Play services are excluded from the tunnel with `addDisallowedApplication`, so they keep
 * working (#458: without the Play services exclusion, FCM cannot reconnect during a pause and a
 * `resume_internet` waits for the next poll). [TunnelBypassPolicy] holds that list.
 *
 * Limits recorded in the ADR: a Private DNS (DoT) setting or an in-app DoH resolver bypasses a DNS
 * sinkhole — onboarding asks the parent to set Private DNS to "Off"/"Automatic" (Android uses the
 * VPN resolver when it is), and the accessibility guard watches the Private DNS screen like any
 * other protection screen. IPv6 queries are answered by the same table (AAAA → `::`).
 */
@AndroidEntryPoint
class FilterVpnService : VpnService() {
    @Inject lateinit var rules: RuleRepository
    @Inject lateinit var blocklist: BlocklistStore
    @Inject lateinit var api: com.familyshield.agent.network.ApiService
    @Inject lateinit var settings: com.familyshield.agent.data.AgentSettings

    /** host → the last time a `web_threat` was posted, so one page load is one attempt. */
    private val lastSiteAlert = java.util.concurrent.ConcurrentHashMap<String, Long>()
    /** host → the last time a visit row was written; a new visit counts only after the quiet gap. */
    private val lastSiteVisit = java.util.concurrent.ConcurrentHashMap<String, Long>()
    /** #830 B2: hosts waiting for the next batched upload, capped by [SITE_VISIT_BATCH_MAX]. */
    private val pendingVisits = java.util.LinkedHashMap<String, Boolean>()
    private val pendingVisitsLock = Any()
    @Volatile private var visitFlusherStarted = false

    private var tun: ParcelFileDescriptor? = null
    private var mode: String = MODE_DNS
    private val running = AtomicBoolean(false)
    private val generation = java.util.concurrent.atomic.AtomicInteger(0)
    private var pump: Thread? = null
    private val workers: ExecutorService = Executors.newFixedThreadPool(4)
    @Volatile private var config: DnsFilterPolicy.Config = DnsFilterPolicy.Config()
    @Volatile private var upstream: List<InetAddress> = emptyList()

    override fun onCreate() {
        super.onCreate()
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopTunnel(); stopSelf(); return START_NOT_STICKY }
            ACTION_RELOAD -> { reloadConfig(); return START_STICKY }
        }
        val wanted = intent?.getStringExtra(EXTRA_MODE) ?: VpnState.mode(this)
        startForegroundCompat()
        reloadConfig()
        if (tun == null || wanted != mode) {
            mode = wanted
            VpnState.setMode(this, mode)
            openTunnel()
        }
        return START_STICKY
    }

    override fun onRevoke() {
        // Another VPN app took the slot, or the child disconnected us from Settings › VPN: tell the parent.
        Log.w(TAG, "VPN revoked")
        VpnState.setRevokedAt(this, System.currentTimeMillis())
        TamperAlertWorker.enqueue(this, TamperAlertWorker.TYPE_VPN_REVOKED)
        stopTunnel()
        stopSelf()
    }

    override fun onDestroy() {
        stopTunnel()
        scope.cancel()
        workers.shutdownNow()
        isRunning = false
        super.onDestroy()
    }

    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

    /**
     * Re-reads the table: first from whatever is cached or on disk (so a fresh process is filtering
     * within milliseconds of the tunnel coming up), then again after a server refresh so a rule the
     * parent just saved is live without waiting for the periodic sync.
     */
    private fun reloadConfig() {
        upstream = systemDnsServers()
        applyRules(rules.cachedRules())
        scope.launch {
            applyRules(rules.currentRules())
            runCatching { rules.refresh() }.getOrNull()?.let { applyRules(it) }
        }
    }

    private fun applyRules(set: com.familyshield.agent.network.dto.RuleSetDto?) {
        val wf = set?.webFilter
        config = DnsFilterPolicy.Config(
            pausedInternet = rules.isInternetPaused(),
            siteNamesEnabled = rules.siteNamesEnabled(),
            safeSearch = wf?.safeSearchEnforced ?: false,
            youtubeMode = wf?.youtubeRestrictedMode ?: "off",
            allowedDomains = wf?.allowedDomains ?: emptyList(),
            blockedDomains = wf?.blockedDomains ?: emptyList(),
            categoryDomains = blocklist.domains(),
        )
    }

    private fun openTunnel() {
        stopTunnel()
        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(MTU)
            .addAddress(TUN_ADDR, 32)
            .addDnsServer(TUN_DNS)
            .setBlocking(true)
        if (mode == MODE_SINKHOLE_ALL) {
            builder.addRoute("0.0.0.0", 0).addRoute("::", 0)
            builder.addAddress(TUN_ADDR6, 128)
        } else {
            // DNS-only: only the fake resolver is routed through us. IPv6 DNS: Android sends queries
            // to the VPN resolver (v4) once the VPN declares one, so no v6 route is needed.
            builder.addRoute(TUN_DNS, 32)
        }
        // Our own traffic, the FCM wake path (pause mode only) and the parent's always-allowed apps
        // bypass the tunnel entirely (#458). The list itself is a pure function so a row can pin it.
        val bypass = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = mode == MODE_SINKHOLE_ALL,
            selfPackage = packageName,
            alwaysAllowedApps = rules.cachedRules()?.alwaysAllowedApps.orEmpty(),
        )
        for (pkg in bypass) runCatching { builder.addDisallowedApplication(pkg) }
        val configure = Intent(this, PairingActivity::class.java)
        builder.setConfigureIntent(PendingIntent.getActivity(this, 0, configure, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        val fd = try {
            builder.establish()
        } catch (e: Exception) {
            Log.w(TAG, "establish failed", e); null
        }
        if (fd == null) {
            Log.w(TAG, "VPN not established (consent missing?)")
            VpnState.setEstablished(this, false)
            return
        }
        tun = fd
        VpnState.setEstablished(this, true)
        VpnState.setRevokedAt(this, 0L)
        running.set(true)
        // #234: only now is there a tunnel. Set after the fd exists, never before, so the dispatcher's
        // wait cannot be satisfied by a service that failed to establish.
        tunnelMode = mode
        val gen = generation.incrementAndGet()
        pump = Thread({ pumpLoop(fd, gen) }, "osra-dns-sinkhole-$gen").also { it.isDaemon = true; it.start() }
        Log.i(TAG, "tunnel up, mode=$mode")
    }

    private fun stopTunnel() {
        // Cleared first, before the fd closes: a re-mode must not briefly claim the old tunnel while
        // the new descriptor is being established (#234 review).
        tunnelMode = null
        running.set(false)
        runCatching { tun?.close() }
        tun = null
        pump = null
        VpnState.setEstablished(this, false)
    }

    private fun pumpLoop(fd: ParcelFileDescriptor, gen: Int) {
        val input = FileInputStream(fd.fileDescriptor)
        val output = FileOutputStream(fd.fileDescriptor)
        val buf = ByteArray(MTU + 64)
        while (running.get() && generation.get() == gen) {
            val n = try { input.read(buf) } catch (e: Exception) {
                // A closed fd ends the loop; only a failure on the *current* tunnel is worth a warning.
                if (running.get() && generation.get() == gen) Log.w(TAG, "tun read: ${e.message}")
                break
            }
            if (n <= 0) continue
            val udp = IpPacket.parseUdp(buf, n) ?: continue // sink everything that is not UDP
            if (udp.dstPort != IpPacket.DNS_PORT) continue   // and every UDP that is not DNS
            val packet = buf.copyOf(n)
            workers.execute { answer(udp, packet, output) }
        }
    }

    private fun answer(udp: IpPacket.Udp, packet: ByteArray, output: FileOutputStream) {
        val q = DnsMessage.parseQuestion(packet, udp.payloadOffset, udp.payloadLength)
        val query = packet.copyOfRange(udp.payloadOffset, udp.payloadOffset + udp.payloadLength)
        val reply: ByteArray? = if (q == null) {
            forward(query)
        } else {
            val d = DnsFilterPolicy.decide(q.name, config)
            when (d.action) {
                DnsFilterPolicy.Action.FORWARD -> forward(query)
                DnsFilterPolicy.Action.SINK -> {
                    if (config.pausedInternet) DnsMessage.buildNxDomain(query, q) else {
                        Log.i(TAG, "sink ${q.name} (${d.reason})")
                        reportBlockedSite(q.name, d.reason)
                        DnsMessage.buildSink(query, q)
                    }
                }
                DnsFilterPolicy.Action.REWRITE -> rewrite(query, q, d.target!!)
            }
        }
        if (reply == null) return
        val ip = IpPacket.buildUdpReply(udp, reply)
        synchronized(output) { runCatching { output.write(ip) } }
    }

    /**
     * #830: a blocked site the child tried to open is one grouped `web_threat` row per host per UTC day.
     * A page load is many DNS queries, so a host is posted at most once per ten minutes and the count
     * increments on later attempts; the server never pushes an aggregate again (ADR-0029).
     */
    private fun reportBlockedSite(host: String, reason: String) {
        if (!reason.startsWith("blocked_domain:") && !reason.startsWith("category:")) return
        val now = System.currentTimeMillis()
        val last = lastSiteAlert[host]
        if (!com.familyshield.agent.enforcement.AlertKeys.siteAlertDue(last, now, SITE_ALERT_QUIET_MS)) return
        if (lastSiteAlert.size > 512) {
            lastSiteAlert.entries.removeIf { now - it.value > SITE_ALERT_QUIET_MS }
        }
        lastSiteAlert[host] = now
        val day = java.time.LocalDate.now(java.time.ZoneOffset.UTC).toString()
        val attempts = com.familyshield.agent.enforcement.AttemptCounter.next(this, "web", host, day)
        scope.launch {
            runCatching {
                api.postInternalAlert(
                    com.familyshield.agent.network.dto.AlertDto(
                        childId = settings.childId(),
                        deviceId = settings.deviceId(),
                        severity = "info",
                        category = "web_threat",
                        title = "Blocked site opened",
                        body = "Your child tried to open a blocked site.",
                        metadata = mapOf("domain" to host, "reason" to reason),
                        dedupeKey = com.familyshield.agent.enforcement.AlertKeys.blockedSite(host, day),
                        attemptCount = attempts,
                    ),
                )
            }
        }
    }

    /**
     * #830: one `url` activity row per host per [SITE_VISIT_QUIET_MS], batched. The DNS filter sees
     * names, not pages, so the payload carries the host in `url` and `domain` and never a path; the
     * server also reduces anything a client sends to its host. With the server flag off an unblocked
     * name never leaves the phone ([SiteVisitGate]); a blocked attempt is the parent's rule reporting
     * itself and is not behind the switch.
     */
    private fun recordSiteVisit(host: String, blocked: Boolean) {
        // One normalised name for the quiet window, the batch and the exclusion check: `q.name` arrives
        // with its DNS casing and a trailing dot, and two spellings of one host split the maps (#841).
        val name = DnsFilterPolicy.normalize(host)
        if (name.isEmpty()) return
        if (!SiteVisitGate.shouldUpload(config.siteNamesEnabled, blocked, SiteVisitGate.isExcludedHost(name))) return
        val now = System.currentTimeMillis()
        val last = lastSiteVisit[name]
        if (!com.familyshield.agent.enforcement.AlertKeys.siteAlertDue(last, now, SITE_VISIT_QUIET_MS)) return
        if (lastSiteVisit.size > 512) {
            lastSiteVisit.entries.removeIf { now - it.value > SITE_VISIT_QUIET_MS }
        }
        lastSiteVisit[name] = now
        val flushNow = synchronized(pendingVisitsLock) {
            pendingVisits[name] = blocked
            pendingVisits.size >= SITE_VISIT_BATCH_MAX
        }
        startVisitFlusher()
        if (flushNow) flushSiteVisits()
    }

    /** One flusher per service lifetime; the scope is cancelled in [onDestroy]. */
    private fun startVisitFlusher() {
        if (visitFlusherStarted) return
        visitFlusherStarted = true
        scope.launch {
            while (true) {
                kotlinx.coroutines.delay(SITE_VISIT_FLUSH_MS)
                flushSiteVisits()
            }
        }
    }

    /** Sends queued names as one batch; a failed upload drops them rather than replaying a day late. */
    private fun flushSiteVisits() {
        val batch: List<Pair<String, Boolean>>
        synchronized(pendingVisitsLock) {
            if (pendingVisits.isEmpty()) return
            batch = pendingVisits.entries.map { it.key to it.value }
            pendingVisits.clear()
        }
        scope.launch {
            val deviceId = settings.deviceId() ?: return@launch
            runCatching {
                api.postActivityEvents(
                    deviceId,
                    com.familyshield.agent.network.dto.ActivityEventBatchDto(
                        events = batch.take(SITE_VISIT_BATCH_MAX).map { (host, blocked) ->
                            com.familyshield.agent.network.dto.ActivityEventDto(
                                type = "url",
                                payload = mapOf("url" to host, "domain" to host, "blocked" to blocked),
                            )
                        },
                    ),
                )
            }
        }
    }

    /** Sends [query] to the first reachable upstream resolver through a protected socket. */
    private fun forward(query: ByteArray): ByteArray? {
        val servers = upstream.ifEmpty { FALLBACK_DNS }
        for (server in servers) {
            val sock = try { DatagramSocket() } catch (e: Exception) { continue }
            try {
                if (!protect(sock)) continue
                sock.soTimeout = UPSTREAM_TIMEOUT_MS
                sock.send(DatagramPacket(query, query.size, InetSocketAddress(server, 53)))
                val resp = ByteArray(4096)
                val p = DatagramPacket(resp, resp.size)
                sock.receive(p)
                return resp.copyOf(p.length)
            } catch (e: SocketTimeoutException) {
                continue
            } catch (e: Exception) {
                continue
            } finally {
                sock.close()
            }
        }
        return null
    }

    /** CNAME rewrite: resolve [target] upstream for the query's type and answer `name CNAME target` + its addresses. */
    private fun rewrite(query: ByteArray, q: DnsMessage.Question, target: String): ByteArray? {
        // A fresh query for the target with the same id/type: header + encoded target name + type/class.
        val tq = java.io.ByteArrayOutputStream()
        tq.write(query, 0, 2); tq.write(0x01); tq.write(0x00); tq.write(0); tq.write(1); tq.write(ByteArray(6))
        tq.write(DnsMessage.encodeName(target)); tq.write(q.type ushr 8); tq.write(q.type and 0xff); tq.write(0); tq.write(1)
        val upstreamReply = forward(tq.toByteArray()) ?: return DnsMessage.buildSink(query, q)
        val addrs = DnsMessage.extractAddresses(upstreamReply, q.type)
        return DnsMessage.buildRewrite(query, q, target, addrs)
    }

    private fun systemDnsServers(): List<InetAddress> {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return emptyList()
        val servers = ArrayList<InetAddress>()
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue
            val lp = cm.getLinkProperties(network) ?: continue
            for (a in lp.dnsServers) if (a is Inet4Address && !a.isLoopbackAddress) servers.add(a)
        }
        return servers.distinct()
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        nm?.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                getString(R.string.notification_channel_content_filter),
                NotificationManager.IMPORTANCE_MIN,
            ).apply { setShowBadge(false) },
        )
        val n: Notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.notification_content_filter_active))
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    companion object {
        /** #830: one `web_threat` per host per ten minutes; a page load issues many DNS queries. */
        private const val SITE_ALERT_QUIET_MS = 10 * 60 * 1000L
        /** #830: a new visit counts only after five quiet minutes for that host (UI/UX's example). */
        private const val SITE_VISIT_QUIET_MS = 5 * 60 * 1000L
        /**
         * #830 B2: visits leave the phone in batches, not one request per name. A page load resolves a
         * dozen names; [SITE_VISIT_FLUSH_MS] bounds how long a name waits, and [SITE_VISIT_BATCH_MAX] is
         * the cap the server also enforces.
         */
        private const val SITE_VISIT_FLUSH_MS = 60_000L
        private const val SITE_VISIT_BATCH_MAX = 20
        /**
         * The mode of the tunnel that is **actually established**, or null when there is none.
         *
         * Issue #234 review: [isRunning] means "the service object exists" — it is set in `onCreate`,
         * before `establish()` runs, and stays true when `establish()` returns null and the service
         * lives on with no fd. So it answers the wrong question: a phone told "internet paused" still
         * passing every packet. This field is written only after `establish()` returned a descriptor
         * and is cleared by [stopTunnel], which every re-mode calls first.
         */
        @Volatile var tunnelMode: String? = null
            private set

        private const val TAG = "FilterVpn"
        const val MODE_DNS = "dns"
        const val MODE_SINKHOLE_ALL = "sinkhole_all"
        const val ACTION_STOP = "com.familyshield.agent.vpn.STOP"
        const val ACTION_RELOAD = "com.familyshield.agent.vpn.RELOAD"
        const val EXTRA_MODE = "mode"
        private const val TUN_ADDR = "10.111.222.1"
        private const val TUN_ADDR6 = "fd00:6f73:7261::1"
        private const val TUN_DNS = "10.111.222.2"
        private const val MTU = 1500
        private const val UPSTREAM_TIMEOUT_MS = 2500
        private const val CHANNEL = "osra_filter"
        private const val NOTIFICATION_ID = 7104
        private val FALLBACK_DNS: List<InetAddress> = listOf("1.1.1.1", "8.8.8.8").map { InetAddress.getByName(it) }

        @Volatile var isRunning: Boolean = false
            private set

        /** True once the parent accepted the OS VPN consent dialog (then `prepare()` returns null). */
        fun isPrepared(context: Context): Boolean = prepare(context) == null

        /** Starts (or re-modes) the tunnel; a no-op until the consent dialog has been accepted. */
        fun start(context: Context, mode: String = VpnState.mode(context)) {
            if (!isPrepared(context)) return
            val i = Intent(context, FilterVpnService::class.java).putExtra(EXTRA_MODE, mode)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i) else context.startService(i)
        }

        fun reload(context: Context) {
            if (!isRunning) { start(context); return }
            context.startService(Intent(context, FilterVpnService::class.java).setAction(ACTION_RELOAD))
        }

        fun stop(context: Context) {
            if (!isRunning) return
            context.startService(Intent(context, FilterVpnService::class.java).setAction(ACTION_STOP))
        }
    }
}
