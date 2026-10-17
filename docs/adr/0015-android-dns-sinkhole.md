# ADR-0015 — Android web filter as a local DNS sinkhole (`VpnService`)

**Status:** Accepted · 2026-10-17 · Phase 1.4 of the KCL plan (`docs/ROADMAP.md`)

## Context

The parent app lets a family block domains and categories, force SafeSearch and set YouTube's
Restricted Mode, and the Windows agent enforces all of it through a local proxy — but on the child's
phone none of it was enforced: the Android agent only blocked *apps*, and `pause_internet` was an
overlay plus app blocking that a background sync, a game's own network stack or a browser tab in
split-screen never noticed. Acceptance for 1.4: *a blocked domain fails in Chrome, Firefox and an
in-app WebView; pause cuts all traffic.*

Platform facts that fix the design: without a device owner, the only way an app can touch another
app's traffic on Android is a `VpnService`; a VPN that routes everything must then forward
everything, which means a user-space TCP/IP stack and a measurable battery and latency cost, and it
makes the agent a man-in-the-middle of the child's traffic — the opposite of what a parental-control
vendor should be. A VPN can instead route **only its own resolver address** into the tunnel: every
app's DNS goes through the agent, every payload byte stays on the real network. Google, Bing,
DuckDuckGo and YouTube all publish DNS-level enforcement hosts for exactly this
(`forcesafesearch.google.com`, `strict.bing.com`, `safe.duckduckgo.com`, `restrict.youtube.com` /
`restrictmoderate.youtube.com`); the same mechanism network admins use on a school router.

## Decision

1. **DNS-only tunnel in normal operation** (`FilterVpnService`): the TUN gets `10.111.222.1/32`,
   declares `10.111.222.2` as the DNS server and routes **only** `10.111.222.2/32`. Android then
   sends every app's resolver traffic to us; nothing else enters the tunnel. Each query is decided
   by `DnsFilterPolicy` (pure, JVM-tested): pause > explicit allow > SafeSearch / YouTube rewrite >
   explicit block > blocked category > forward. Forwarded queries go to the real network's resolvers
   through `protect()`ed UDP sockets (fallback 1.1.1.1 / 8.8.8.8); sunk names get an `A 0.0.0.0` /
   `AAAA ::` with a 30-s TTL (browsers show "can't be reached" and do not retry around it);
   rewrites answer `name CNAME host` plus the host's real addresses, so the browser lands on the
   enforcement host and the engine does the rest.
2. **Pause-internet takes the default route** (`MODE_SINKHOLE_ALL`): `0.0.0.0/0` and `::/0` into
   the tunnel, every packet read and dropped, DNS answered NXDOMAIN. The agent itself and the
   parent's *always-allowed apps* are excluded with `addDisallowedApplication`, so the agent keeps
   polling for `resume_internet` and the apps the parent chose keep working. The overlay stays —
   it is what tells the child why.
3. **Blocked categories come from the blocklist pack**: `BlocklistStore` already merged
   `appsAndroid` per blocked category; it now merges `domains` the same way (`mergeDomains`) and
   persists them, so the table survives a failed refresh and a reboot.
4. **One-time consent in onboarding**: the OS VPN dialog is shown from the "Set up web filter" row
   (status screen and setup-complete screen), `VpnState.enabled` is set on OK, and the boot receiver
   restarts the tunnel. Rules sync (`RulesSyncWorker`) sends `ACTION_RELOAD` after every refresh so a
   changed filter is live within the sync interval, and the `pause_internet` / `resume_internet`
   commands switch the mode immediately.
5. **Revocation is tamper**: `onRevoke` (another VPN app took the slot, or the child disconnected
   the VPN in Settings) posts a `tamper` alert `content_filter_disconnected` through the same
   expedited worker as ADR-0010 and the status row shows "not connected / Reconnect"; the next rules
   sync (and any `pause_internet` / `resume_internet`) restarts the tunnel if the slot is free, so a
   one-off disconnect heals itself without the parent doing anything. The existing
   `vpn_detected` check (feature #20) stands down while our own tunnel is established — Android runs
   one VPN at a time, so the VPN transport is ours.
6. **Foreground service type `specialUse`** with the `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` text Play
   asks for; the notification is `IMPORTANCE_MIN`.

## Reasoning

- DNS-only is the cheapest enforcement that covers *every* app, browser and WebView at once, because
  all of them resolve names through the system resolver when a VPN declares one. The agent never
  sees a URL, a header or a payload.
- Sinking to `0.0.0.0` rather than NXDOMAIN in filter mode: Chrome retries NXDOMAIN against its
  own DoH list on some channels and some apps treat it as "offline"; a resolved-to-nowhere address
  fails fast and quietly. Pause mode wants the opposite (nothing resolves), hence NXDOMAIN there.
- The rewrite is a CNAME with the target's addresses copied from a real upstream answer, not a
  hard-coded IP: the enforcement hosts move between Google front-ends and a stale IP would break
  search altogether.
- `addDisallowedApplication` for the agent instead of `protect()` on every socket: Retrofit, FCM
  and WorkManager open sockets we never see; excluding the package is the one switch that covers
  them all.

## Rejected alternatives

- **Full-tunnel proxy** (tun2socks / a user-space TCP stack, as commercial filters do): covers
  SNI/HTTPS inspection and per-app bandwidth, costs a native library, battery, and makes the agent a
  MITM of a child's traffic. Not what a family asked for; revisit only if a category needs URL-level
  (not host-level) decisions.
- **Per-app proxy via `ConnectivityManager` / Chrome policy**: Chrome's managed policies need a
  device owner or an EMM; WebViews and Firefox ignore them.
- **Device-owner-only enforcement** (`setGlobalPrivateDnsHost`): correct and strong, but requires the
  owner provisioning flow (1.8/5.x); the sinkhole works on the tier every family actually has.
- **Hosts-file / root**: not available on a consumer phone.

## Costs and limits (recorded, not hidden)

- **Private DNS (DoT)**: if the phone's Private DNS is set to a named host, Android resolves through
  it and bypasses the VPN resolver. Onboarding (1.6) asks the parent to set Private DNS to
  *Automatic* or *Off*; the accessibility guard treats the Private DNS screen as a protection
  screen (added to `TamperScreenPolicy` in 1.6 with the onboarding checks).
- **In-app DoH**: an app that ships its own DNS-over-HTTPS resolver (Firefox with DoH forced on,
  some ad-blockers) bypasses any DNS filter. Chrome auto-upgrades to DoH only when the system
  resolver is a known provider — a `10.x` resolver is not, so Chrome stays on the sinkhole.
- **IPv6**: the tunnel declares only an IPv4 resolver; Android uses the VPN's resolvers for all
  queries, so AAAA questions reach us too and are answered by the same table (`::` sink).
- **IP-literal access** (`http://93.184.216.34/`) is not filtered; neither is it by any DNS filter.
- One VPN slot: a child who installs another VPN app can take the slot — that is the
  `content_filter_disconnected` alert; preventing it needs the device-owner tier.
- The battery cost is one UDP round trip per DNS query; no payload traffic is proxied.

## Verification

Unit: `DnsFilterPolicyTest` (precedence, suffix matching, engine host tables, no rewrite loops),
`DnsMessageTest` (parse, sink, NXDOMAIN, CNAME rewrite, address extraction), `IpPacketTest` (IPv4/IPv6
UDP build/parse round trips, RFC 1071 checksum). Hardware: `docs/TESTING.md` §5c.
