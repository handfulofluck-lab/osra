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
 * without a device owner; the parent's always-allowed apps and the agent itself are excluded from
 * the tunnel with `addDisallowedApplication`, so they keep working.
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

    private var tun: ParcelFileDescriptor? = null
    private var mode: String = MODE_DNS
    private val running = AtomicBoolean(false)
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
        // Our own traffic and the parent's always-allowed apps bypass the tunnel entirely.
        runCatching { builder.addDisallowedApplication(packageName) }
        for (pkg in rules.cachedRules()?.alwaysAllowedApps.orEmpty()) runCatching { builder.addDisallowedApplication(pkg) }
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
        pump = Thread({ pumpLoop(fd) }, "osra-dns-sinkhole").also { it.isDaemon = true; it.start() }
        Log.i(TAG, "tunnel up, mode=$mode")
    }

    private fun stopTunnel() {
        running.set(false)
        runCatching { tun?.close() }
        tun = null
        pump = null
        VpnState.setEstablished(this, false)
    }

    private fun pumpLoop(fd: ParcelFileDescriptor) {
        val input = FileInputStream(fd.fileDescriptor)
        val output = FileOutputStream(fd.fileDescriptor)
        val buf = ByteArray(MTU + 64)
        while (running.get()) {
            val n = try { input.read(buf) } catch (e: Exception) { if (running.get()) Log.w(TAG, "tun read", e); break }
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
            NotificationChannel(CHANNEL, "Content filter", NotificationManager.IMPORTANCE_MIN).apply { setShowBadge(false) },
        )
        val n: Notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Content filter active")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    companion object {
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
