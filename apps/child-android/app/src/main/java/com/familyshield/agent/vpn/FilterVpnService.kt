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
import android.os.Handler
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
    // S1 (osra-security#39): this service became a collector in #830/#841, so it is the one collector that
    // has to consult the consent pause itself. ADR-0008 §3 pauses enforcement and collection together.
    @Inject lateinit var consent: com.familyshield.agent.data.ConsentState

    /** host → the last time a `web_threat` was posted, so one page load is one attempt. */
    private val lastSiteAlert = java.util.concurrent.ConcurrentHashMap<String, Long>()
    /** host → the last time a visit row was written; a new visit counts only after the quiet gap. */
    private val lastSiteVisit = java.util.concurrent.ConcurrentHashMap<String, Long>()
    /** #830 B2: hosts waiting for the next batched upload, capped by [SITE_VISIT_BATCH_MAX]. */
    private val pendingVisits = java.util.LinkedHashMap<String, Boolean>()
    private val pendingVisitsLock = Any()
    private val visitFlusherStarted = java.util.concurrent.atomic.AtomicBoolean(false)

    private var tun: ParcelFileDescriptor? = null
    // A failed re-mode can close the old descriptor before Android delivers its revocation callback.
    private val hadEstablishedTunnel = AtomicBoolean(false)
    private val lifecycleHandler by lazy { Handler(mainLooper) }
    private var mode: String = MODE_DNS
    @Volatile private var authorizedMode: String = MODE_DNS
    @Volatile private var serviceStopping: Boolean = false
    private val transientResetController = WebFilterConnectionReset.TransientTunnelController(
        readSnapshot = {
            WebFilterConnectionReset.ServiceSnapshot(
                authorizedMode = authorizedMode,
                activeMode = tunnelMode,
                internetPaused = rules.isInternetPaused(),
                consentPaused = consent.isPaused(),
                lockActive = com.familyshield.agent.enforcement.LockState.isActive(this),
                stopping = serviceStopping,
            )
        },
        openMode = { wanted ->
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) {
                openTunnelForMode(wanted)
            }
        },
        closeTunnel = {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) {
                stopTunnel()
            }
        },
    )
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
            ACTION_STOP -> {
                serviceStopping = true
                transientResetController.interruptTransientHold()
                completeAllPendingResets(WebFilterConnectionReset.TransitionOutcome.STOPPED)
                hadEstablishedTunnel.set(false)
                stopTunnel()
                VpnState.clearFilterLoss(this)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RELOAD -> { reloadConfig(); return START_STICKY }
            ACTION_FLUSH_VISITS -> { flushSiteVisits(); return START_STICKY }
            ACTION_RESET_CONNECTIONS -> {
                val reqId = intent.getStringExtra(EXTRA_RESET_REQUEST_ID)
                scope.launch {
                    val outcome = runCatching { transientResetController.executeReset() }
                        .getOrDefault(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED)
                    if (reqId != null) {
                        pendingResetRequests.remove(reqId)?.complete(outcome)
                    }
                }
                return START_STICKY
            }
        }
        val wanted = intent?.getStringExtra(EXTRA_MODE) ?: VpnState.mode(this)
        serviceStopping = false
        authorizedMode = wanted
        VpnState.setMode(this, wanted)
        transientResetController.interruptTransientHold()
        startForegroundCompat()
        reloadConfig()
        if (tun == null || wanted != mode) {
            mode = wanted
            openTunnel()
        }
        return START_STICKY
    }

    override fun onRevoke() {
        // Android can call this off the main thread. Serialize with start, re-mode and stop.
        lifecycleHandler.post {
            Log.w(TAG, "VPN revoked")
            serviceStopping = true
            transientResetController.interruptTransientHold()
            completeAllPendingResets(WebFilterConnectionReset.TransitionOutcome.STOPPED)
            try {
                if (VpnState.recordFilterLoss(this, settings, consent, hadEstablishedTunnel.getAndSet(false))) {
                    TamperAlertWorker.enqueue(this, TamperAlertWorker.TYPE_VPN_REVOKED)
                }
            } finally {
                stopTunnel()
                stopSelf()
            }
        }
    }

    override fun onDestroy() {
        // A system revoke can already be queued on the main looper. Keep this instance's
        // established latch until that callback consumes it or an explicit stop clears it.
        serviceStopping = true
        transientResetController.interruptTransientHold()
        completeAllPendingResets(WebFilterConnectionReset.TransitionOutcome.STOPPED)
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
            // #1079: the two facts that decide whether those domains are the whole story. Without them the
            // table cannot tell an empty pack from a family that blocks nothing (Hydrogen's #1097 review).
            packLoaded = blocklist.packStored(),
            blockedCategories = wf?.blockedCategories ?: emptyList(),
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
        running.set(true)
        // #234: only now is there a tunnel. Set after the fd exists, never before, so the dispatcher's
        // wait cannot be satisfied by a service that failed to establish.
        tunnelMode = mode
        val gen = generation.incrementAndGet()
        pump = Thread({ pumpLoop(fd, gen) }, "osra-dns-sinkhole-$gen").also { it.isDaemon = true; it.start() }
        hadEstablishedTunnel.set(true)
        VpnState.clearFilterLoss(this)
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

    private fun openTunnelForMode(wanted: String): Boolean {
        if (serviceStopping) return false
        upstream = systemDnsServers()
        applyRules(rules.cachedRules())
        mode = wanted
        openTunnel()
        return tun != null && tunnelMode == wanted
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
        } else if (consent.isPaused()) {
            if (mode == MODE_SINKHOLE_ALL && authorizedMode == MODE_DNS) {
                transientResetController.interruptTransientHold()
            }
            // S1 (osra-security#39): while consent is withdrawn the tunnel filters nothing and records
            // nothing. Whatever was queued for upload is dropped here rather than flushed after a re-grant,
            // which is what made a withdrawn window's browsing history reach the server.
            synchronized(pendingVisitsLock) { pendingVisits.clear() }
            forward(query)
        } else {
            val d = DnsFilterPolicy.decide(q.name, config)
            when (d.action) {
                DnsFilterPolicy.Action.FORWARD -> {
                    // #830/#841: the visit row is gated inside recordSiteVisit, which uploads nothing
                    // while the flag is off. Both call sites are pinned by Reporting830WiringTest so a
                    // later merge cannot drop the feature and leave the tests green.
                    recordSiteVisit(q.name, blocked = false)
                    forward(query)
                }
                DnsFilterPolicy.Action.SINK -> {
                    if (config.pausedInternet) DnsMessage.buildNxDomain(query, q) else {
                        Log.i(TAG, "sink ${q.name} (${d.reason})")
                        recordSiteVisit(q.name, blocked = true)
                        reportBlockedSite(q.name, d.reason)
                        DnsMessage.buildSink(query, q)
                    }
                }
                DnsFilterPolicy.Action.REWRITE -> {
                    // #830 row 5: SafeSearch and YouTube Restricted Mode are enabled by default for every child,
                    // so Google, Bing, DuckDuckGo and YouTube lookups take REWRITE rather than FORWARD. Record the
                    // queried host (gated by SiteVisitGate); the CNAME target stays excluded by SiteVisitGate.
                    recordSiteVisit(q.name, blocked = false)
                    rewrite(query, q, d.target!!)
                }
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
        // S1: before AttemptCounter.next, not after it. The counter is persisted on disk, so a paused window
        // that incremented it would add its attempts to the first count the parent sees after a re-grant.
        if (consent.isPaused()) return
        if (!reason.startsWith("blocked_domain:") && !reason.startsWith("category:")) return
        // #841 review: the visit path normalises `q.name`, this one did not — mixed case or a trailing
        // dot split the quiet window, the attempt counter and the dedupe key, and slid past the
        // exclusion list. One normalised name, and an excluded or empty one is not reported at all.
        val name = DnsFilterPolicy.normalize(host)
        if (name.isEmpty() || SiteVisitGate.isExcludedHost(name)) return
        // Fable's blocker D: one read of the flag for the whole alert, so a single row cannot be built
        // half in each state; while it is off the quiet window and the counter use a hostless key, so the
        // parent's count is the day's total rather than the largest single host's.
        val siteNames = config.siteNamesEnabled
        val alertKey = if (siteNames) name else "blocked-day"
        val now = System.currentTimeMillis()
        val last = lastSiteAlert[alertKey]
        if (!com.familyshield.agent.enforcement.AlertKeys.siteAlertDue(last, now, SITE_ALERT_QUIET_MS)) return
        if (lastSiteAlert.size > 512) {
            lastSiteAlert.entries.removeIf { now - it.value > SITE_ALERT_QUIET_MS }
        }
        lastSiteAlert[alertKey] = now
        val day = java.time.LocalDate.now(java.time.ZoneOffset.UTC).toString()
        val attempts = com.familyshield.agent.enforcement.AttemptCounter.next(this, "web", alertKey, day)
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
                        // Claude's ruling on #841 finding 5: with the flag off the attempt is still
                        // reported, but the parent gets a count with no host — no domain, a coarse reason
                        // (never the blocked word itself) and one row per day.
                        metadata = if (siteNames) {
                            mapOf("domain" to name, "reason" to reason)
                        } else {
                            mapOf("reason" to reason.substringBefore(':'))
                        },
                        dedupeKey = if (siteNames) {
                            com.familyshield.agent.enforcement.AlertKeys.blockedSite(name, day)
                        } else {
                            "web:$day"
                        },
                        attemptCount = attempts,
                    ),
                )
            }
        }
    }

    /**
     * #830: one `url` activity row per host per [SITE_VISIT_QUIET_MS], batched. The DNS filter sees
     * names, not pages, so the payload carries the host in `url` and `domain` and never a path; the
     * server also reduces anything a client sends to its host. With the flag off **no** name leaves the
     * phone, blocked or not ([SiteVisitGate], Fable's blocker A); the blocked attempt still reaches the
     * parent as a hostless count through its alert.
     */
    private fun recordSiteVisit(host: String, blocked: Boolean) {
        if (consent.isPaused()) return
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
        // One flusher, whatever the worker race: compare-and-set, not a check-then-set (#841 review).
        if (!visitFlusherStarted.compareAndSet(false, true)) return
        scope.launch {
            while (true) {
                kotlinx.coroutines.delay(SITE_VISIT_FLUSH_MS)
                flushSiteVisits()
            }
        }
    }

    /** Sends queued names as one batch; a failed upload drops them rather than replaying a day late. */
    private fun flushSiteVisits() {
        if (consent.isPaused()) {
            // S1: a pause drains the queue instead of uploading it. Without this the 60 s flusher posts the
            // withdrawn window's names on the next tick, or the moment consent comes back.
            synchronized(pendingVisitsLock) { pendingVisits.clear() }
            return
        }
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
                        // The whole drained batch: the API accepts up to 200 events, and truncating to the
                        // queue cap after clearing the map dropped whatever four workers had just added.
                        events = batch.map { (host, blocked) ->
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
        private const val SITE_VISIT_FLUSH_MS = 15_000L
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
        const val ACTION_FLUSH_VISITS = "com.familyshield.agent.vpn.FLUSH_VISITS"
        const val ACTION_RESET_CONNECTIONS = "com.familyshield.agent.vpn.RESET_CONNECTIONS"
        private const val EXTRA_RESET_REQUEST_ID = "reset_request_id"
        private val resetRequestSeq = java.util.concurrent.atomic.AtomicLong(0L)
        private val pendingResetRequests =
            java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<WebFilterConnectionReset.TransitionOutcome>>()

        private fun completeAllPendingResets(outcome: WebFilterConnectionReset.TransitionOutcome) {
            val keys = pendingResetRequests.keys.toList()
            for (k in keys) {
                pendingResetRequests.remove(k)?.complete(outcome)
            }
        }
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

        /** Flushes any queued site visits when the screen turns off (#830 row 5); no-op when stopped. */
        fun flushIfRunning(context: Context) {
            if (!isRunning) return
            runCatching { context.startService(Intent(context, FilterVpnService::class.java).setAction(ACTION_FLUSH_VISITS)) }
        }

        /**
         * Re-applies the cached rules to the running filter. [startIfStopped] is false where the caller
         * may not adopt "a rule change revives the VPN" as a policy: the `rules_updated` command path
         * passes false (Kimi, #848), because starting the service from a rule edit would also undo a
         * paused or not-yet-consented state. `RulesSyncWorker` keeps the default, which is the behaviour
         * it already had.
         */
        fun reload(context: Context, startIfStopped: Boolean = true) {
            if (!isRunning) { if (startIfStopped) start(context); return }
            context.startService(Intent(context, FilterVpnService::class.java).setAction(ACTION_RELOAD))
        }

        fun stop(context: Context) {
            VpnState.clearFilterLoss(context)
            if (!isRunning) return
            context.startService(Intent(context, FilterVpnService::class.java).setAction(ACTION_STOP))
        }

        /**
         * #1224: dispatches a service-owned transient connection reset to an already-running `MODE_DNS`
         * tunnel (#848: never starts a stopped service) and awaits the actual completed [WebFilterConnectionReset.TransitionOutcome].
         */
        suspend fun awaitConnectionReset(
            context: Context,
            timeoutMs: Long = 15_000L,
        ): WebFilterConnectionReset.TransitionOutcome {
            if (!isRunning || tunnelMode != MODE_DNS || !VpnState.isEnabled(context) || !isPrepared(context)) {
                return WebFilterConnectionReset.TransitionOutcome.SKIPPED
            }
            val reqId = "reset-${resetRequestSeq.incrementAndGet()}"
            val deferred = kotlinx.coroutines.CompletableDeferred<WebFilterConnectionReset.TransitionOutcome>()
            pendingResetRequests[reqId] = deferred
            try {
                val started = runCatching {
                    context.startService(
                        Intent(context, FilterVpnService::class.java)
                            .setAction(ACTION_RESET_CONNECTIONS)
                            .putExtra(EXTRA_RESET_REQUEST_ID, reqId),
                    )
                }.getOrNull()
                if (started == null) {
                    return WebFilterConnectionReset.TransitionOutcome.SKIPPED
                }
                return kotlinx.coroutines.withTimeoutOrNull(timeoutMs) { deferred.await() }
                    ?: WebFilterConnectionReset.TransitionOutcome.SKIPPED
            } finally {
                pendingResetRequests.remove(reqId)
            }
        }
    }
}
