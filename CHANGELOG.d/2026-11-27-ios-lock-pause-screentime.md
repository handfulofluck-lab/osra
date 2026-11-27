### iPhone child — Lock, Pause and Pause internet work through Screen Time (#1089, epic #1092)
- The iPhone child now enforces `lock` and `pause` by shielding every app category and every web domain in a
  dedicated Screen Time store, and `unlock`/`resume` clear that store only — the child's own rules and the
  bedtime/routine shields are untouched.
- `pause_internet` uses its own store, so resuming the internet never lifts a lock and unlocking never resumes
  the internet. iOS cannot cut the network itself, so the honest description is "apps and websites".
- Lock and Pause leave OSRA Kids and Phone unshielded, so a force-quit child can reopen the app and receive
  the parent's Unlock; the parent's always-on app list is honoured too. A shield without Screen Time
  authorization (`not_authorized`) or without a resolvable OSRA exemption (`osra_token_unavailable`) is refused
  instead of being reported as applied.
- As a second recovery path, a parent Lock or Pause lifts by itself after 24 hours even if the child never
  reopens OSRA; a shield whose safety interval cannot be scheduled is refused (`failsafe_not_scheduled`).
- Pause internet also applies the WebKit filter, so uncategorised sites do not remain open in Safari.
- Every such command is acked from what the store actually did: `ok` when the policy took, `failed` with a
  reason (`shield_not_applied`, `shield_still_applied`, `not_authorized`) when it did not — never a silent success.
- The server's capability table no longer marks `lock_screen`, `pause_screen` and `pause_internet` as
  unsupported for iOS, and `unlock` is no longer a refused command, so the parent app's "Not yet available"
  chips (epic #1092) disappear for these controls when the build ships. `ring` stays unsupported (#750).

Not verified on a handset yet: the acceptance for this is Codex's device row — Lock shields within ~10 s of
the push, Unlock restores, Pause internet shields Safari and apps, force-quit and reopen keep the state, and
earlier app-group blocks survive Unlock.
