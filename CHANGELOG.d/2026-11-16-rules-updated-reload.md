### Android — a web-filter change reaches the running filter without a restart (#826)
- On the Flip4 (15 Nov) a parent's blocked-domain change was acked at once, but the running
  `FilterVpnService` kept answering with its old config for 10+ minutes; only a pause → resume cycle
  (which restarts the service) applied it. `rules_updated` refreshed the stored rules and never
  reloaded the filter — only `RulesSyncWorker` did.
- The command path now calls `FilterVpnService.reload(context, startIfStopped = false)` after the refresh,
  so the new blocked list, category list and Restricted Mode are live within seconds of the ack. The order
  matters and is held by a JVM row; a refresh that fails still reloads from the cached set.
- **A rule edit does not revive a stopped filter** (Kimi's #848 question): `reload`'s `startIfStopped` is
  false on this path, so a paused state or a VPN consent the child has not given is not undone by an
  unrelated rule change. `RulesSyncWorker` keeps its existing start-the-service behaviour. A failed
  refresh or reload is logged, not swallowed — the silence is what let #826 last 10+ minutes.
- Tests: ordering (refresh then reload), a throwing refresh still reloading, a throwing reload not
  undoing the refresh, and a source row pinning that the `rules_updated` branch calls both — the Call
  that was missing. The tunnel-level effect is device evidence, not JVM evidence.
