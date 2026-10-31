### Child agent — a pause no longer cuts the wake path, so "resume internet" lands at once (#458)
- Found on the Flip4 during #451's rows: with the `sinkhole_all` pause up, `resume_internet` sat pending
  for about two minutes and landed only when the agent's jobs were force-run. The pause tunnel captures
  every app, Google Play services included, so once FCM's socket dropped it could not reconnect — and the
  resume then waited for the next poll, which can be up to 15 minutes. A pause a parent cannot lift
  quickly is worse than the pause.
- The tunnel now passes `com.google.android.gms` to `addDisallowedApplication` **in pause mode only**,
  so the push wake path stays open. The DNS-only tunnel is unchanged: it routes a single address and a
  wider exclusion list would be surface with no reason.
- **The trade, in the code and in this entry:** Play services traffic is no longer sunk during a pause.
  That is accepted because it is not content a child can browse with. The Play Store
  (`com.android.vending`) is *not* excluded and stays inside the sinkhole, and the row asserts it.
- The list is a pure function, `TunnelBypassPolicy.excludedPackages(sinkholeAll, selfPackage,
  alwaysAllowedApps)`: the agent's own package first (its poll must never land in its own sinkhole),
  then Play services in pause mode, then the family's always-allowed apps, de-duplicated and
  blank-filtered (`VpnService.Builder` throws on an empty name, which would read in a log as applied).
  `FilterVpnService.openTunnel` applies exactly that list and does no filtering of its own.
- Rows: `TunnelBypassPolicyTest`, six of them — pause excludes gms; DNS-only does not; the agent is
  first; an always-allowed gms is not added twice; blanks never reach the builder; the Play Store is not
  excluded. Mutant: delete the `if (sinkholeAll) packages += FCM_PACKAGE` line and the pause row goes
  red (verified locally before pushing).
- **Not verified by code, and it is the row that matters:** pause, drop the network briefly, then
  resume — the resume should land in under five seconds on the Flip4. That is Claude's phone queue.
