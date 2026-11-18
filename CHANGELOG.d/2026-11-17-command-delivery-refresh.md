### Parent app — the command delivery list refreshes after a save and on pull-down (#876)
- Saving a rule now invalidates every device's command history for that child, so the `rules_updated` row
  and its delivery state appear without leaving the screen. The cached list survived the save because only
  the rules and family providers were invalidated.
- The child **Overview** tab and the full **Command delivery** screen both gain a pull-to-refresh gesture.
  Neither had one: the only manual refresh was the Retry button on an error state, so a pull-down did nothing.
- The existing `rules_applied` frame now also refreshes the delivery lists — the same frame that clears the
  "hasn't picked this change up yet" line says the rules command landed. No poll loop is added.
- **Expectation until the phone half of #865 lands:** `rules_applied` arrives only after the phone's next
  usage report, so the automatic pending-to-delivered step can still take 12 to 14 minutes. The pull-down is
  immediate.
- Verified: `flutter analyze` clean and the suite green in CI at `ab6a1194`; no Flutter SDK on the authoring
  host, so nothing is claimed as a local run. The Mac test bed's re-run (save a rule, watch the row appear
  without leaving the screen) is the device proof.
