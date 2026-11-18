### Child Android — a category block is live on the next reload, not at the next sync (#864)
- Karim's Flip4 repro (case B6): YouTube unblocked and blocked again from the parent left the site open, and
  adding `youtube.com` to the domain filter did not take effect until the phone was restarted.
- Root cause found in the code, not guessed: the rule set and the category pack are **two stores**.
  `FilterVpnService.reloadConfig()` refreshed the rules and then rebuilt the DNS config, but
  `applyRules` reads `categoryDomains = blocklist.domains()`, and the pack was fetched only by
  `RulesSyncWorker`. A reload therefore rebuilt the filter against the pack the last periodic sync had
  stored, so any change expressed as a **category** waited for the worker.
- The reload now re-fetches the pack, merged against the fresh rule set's `blockedCategories`, before it
  rebuilds the filter. A failed fetch keeps the previous pack rather than emptying it, matching
  `BlocklistStore.refresh`'s documented behaviour.
- New row `a reload re-fetches the category pack, not only the rule set`: it reads `reloadConfig()` and
  fails if `blocklist.refresh(` or `blockedCategories` is dropped. Proven red against the old source
  (pack refresh absent) and green against the new one.
- Not claimed: the real tunnel's behaviour. What is left on the issue is a Flip4 capture — one category
  toggle plus one explicit domain toggle with `logcat -s CommandDispatcher FilterVpnService` — which
  separates "command never arrived" from "reload skipped" from "pack stale".
