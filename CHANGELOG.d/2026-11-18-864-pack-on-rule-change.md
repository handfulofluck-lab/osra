### Child Android — a category block is live on every rules path, not at the next sync (#864)
- Karim's Flip4 repro (case B6): YouTube unblocked and blocked again from the parent left the site open, and
  `youtube.com` added to the domain filter did not take effect until a restart.
- Root cause in the code: the rule set and the category pack are **two stores**. `BlocklistStore` feeds both the
  DNS sinkhole (`domains()`) and app blocking (`apps()`, read by `RuleRepository.verdict`), and it was fetched only
  by `RulesSyncWorker`. So after a rules refresh the filter rebuilt itself against a pack from the last sync.
- The pack is now re-fetched inside `RuleRepository.refresh()`, under `refreshMutex`, after `cached = updated` and
  **before** the `#444 C4` listeners run (Antigravity's `#922` review). That fixes three paths at once: the
  `rules_updated` command, the periodic worker, and consent re-grant — and it works when the VPN tunnel is not
  running, which a `FilterVpnService.reloadConfig()` fix could not.
- `RulesSyncWorker` no longer fetches the pack itself: that was a second `GET /v1/blocklists` per sync.
- `BlocklistStore.refresh` is called directly, not inside `runCatching`: it rethrows `CancellationException` and
  handles ordinary failures itself.
- Rows: `the rule refresh re-fetches the category pack before the C4 listeners run` fails if the call is deleted or
  moved after the listeners; `the VPN reload no longer owns the pack refresh` fails if it moves back.
- Not claimed: the tunnel's behaviour on the Flip4. `Part of #864` — the device row still owns that.
