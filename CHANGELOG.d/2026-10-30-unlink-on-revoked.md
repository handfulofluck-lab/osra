### Child agent — a phone whose family was deleted stops enforcement and releases itself (#465)
- **What went wrong.** Deleting the family (#464) deletes the child's device rows, so the agent's next
  poll gets `401 device_revoked`. The agent threw on any non-2xx and retried forever; `clearPairing()` was
  reachable only from the PIN-gated Re-pair button, and device admin came off only through the PIN-gated
  removal. So a deleted family's phone kept enforcing its last rules and kept a device-admin grant nobody
  could remove — the parent account that would have unpinned it no longer existed, and the child cannot
  uninstall a device admin. Play expects deleting an account to release the device.
- **One definite signal, read in one place.** `DeviceRevoked.isRevoked` is true only for `401` with body
  code `device_revoked`; a network error, a 5xx, a plain `401` a token refresh could fix, and a
  `device_revoked_other` all return false. `codeFromBody` reads the field rather than substring-matching
  the body, so a look-alike code cannot pass.
- **Two answers, a minute apart.** `UnlinkPolicy` confirms on the second answer at least 60 s after the
  first; a second answer arriving sooner keeps the original timestamp, so a flapping server cannot confirm
  by answering twice quickly; any `200` resets the count. Once unlinked it stays unlinked.
- **The unlink itself, in the issue's order:** stop the VPN, clear the lock state, forget the rules (two
  new methods — `AgentSettings.forgetRules`, `RuleRepository.forgetRules`; without them the last
  server-sent ruleset is exactly what the phone keeps enforcing), `clearPairing()`, drop device admin
  without the PIN, then notify.
- **Rows:** U1 (one answer does not unlink, a second a minute later does), U1b (a second answer too soon
  keeps waiting and keeps the timestamp), U2 (5xx / plain 401 / wrong code / 403 all false), U2b
  (`codeFromBody` reads the field, and `device_revoked_other` does not equal `device_revoked`), U3 (nothing
  polls after the unlink and a later good answer cannot re-link), U4 (a `200` between the answers resets).
- **Faults, run not asserted:** unlink on the first answer → U1, U1b and U4 red (all three waiting rows,
  because the wait is what they assert); unlink on any 401 → U2 alone; keep polling after the unlink → U3
  alone. Restored byte-identical afterwards.
- **Not in this change:** the full-screen "no longer linked" Activity. The notification carries the two
  sentences from the issue (English; the Arabic goes to Karim). The behaviour — stop enforcing, release the
  admin, become uninstallable — is in.
