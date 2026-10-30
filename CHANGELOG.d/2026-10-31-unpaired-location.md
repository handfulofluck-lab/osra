### Child agent — an unlinked phone no longer starts the location service (#472)
- Found on the Flip4 during the #466 hardware row: after the family was deleted and the agent had
  unlinked itself, launching the app started `LocationService` again 41 seconds later and left its
  ongoing "Location" notification on a phone nobody manages — beside the unlink notice that says the
  app can now be uninstalled.
- **The link is now an input to the start rule.** `LocationStartPolicy.decide` takes `isPaired` first
  and returns `Decision.UNPAIRED` (`reason = "not_paired"`) before it looks at a single grant: an
  unlinked phone has no child to locate, and "grant more permissions" is the wrong thing to tell a
  family that just deleted its account. Every call site reads the pair state rather than defaulting it:
  `BootStartPolicy`/`BootReceiver`, `AccessibilityMonitorService`, `CommandDispatcher.locate_now`, all
  via `EntryPointAccessors` where a receiver has no injection.
- `PairingActivity.startLocationServiceIfPermitted()` returns early when nothing is paired. That method
  is a *foreground* start, so it does not go through the background rule — which is exactly why the
  observed relaunch started the service.
- The two classifiers that describe a **grant** rather than a link (`LocationGrantState` for telemetry,
  `LocationStatusPolicy` for the status line) ask the policy with `isPaired = true` and document why:
  inventing an "unpaired" value would either change the server's telemetry vocabulary or put a dead
  line on a screen only shown to paired devices.
- Rows: `LocationStartPolicyTest` (unpaired refused before any grant; a paired phone still gets
  `location_permission_missing`), `BootStartPolicyTest` (no start at boot), and
  `AccessibilityMonitorLocationStartTest` (an unpaired device is `UNPAIRED`, not "nothing to do").
  Mutant: delete `if (!isPaired) return Decision.UNPAIRED` and all three go red with `START`.
