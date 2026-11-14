### API — the capability vocabulary learns `child_account_admin` (#663)
- **What:** `FEATURE_KEYS` in `packages/shared-types` gains `child_account_admin`, the fact ADR-0041 D5.5 asks
  the parent app to warn about: `ready` = the child's own Windows or Mac account is a standard user;
  `degraded` = it is an administrator, so protection is weak on that computer; `unavailable`/`not_supported` =
  the computer cannot report the fact; absent = not reported, which is every Android and iOS device.
- **Why a state and not the issue's "boolean":** a boolean has no way to say "nothing was reported". Absent
  must not read as `ready`, or a phone, or a computer whose agent cannot read the account type, would look
  safe while nothing was checked.
- **Computers only, refused at the door:** `parseCapabilities` refuses the key from any `client.app` but
  `agent-desktop` and `agent-macos` and names the app that sent it
  (`features.child_account_admin: child-android cannot report it; …`), so a phone's report can never put a
  Windows/Mac administrator row on its setup screen, and the key cannot reach the "what to fix" list, which
  carries grants only.
- **Not wired end to end yet:** no agent sends the key and the parent app does not read it — those are the
  other lanes of #663. Until a desktop agent reports it, the key is absent, which the vocabulary already
  means, so nothing changes for any device in the field.
- **Tests:** `services/api/test/capabilities-child-admin.test.ts` (13 rows) — accepted for `windows`/
  `agent-desktop` and `macos`/`agent-macos` in both warning states, refused for `child-android` and
  `child-ios` with the named issue, an Android report without the key unaffected, and `banana` refused by the
  existing enum. Proven to fail: with the platform rule forced to allow every app, the three refusal rows go
  red; with `banana` added to `FEATURE_STATES`, the invalid-state row goes red. Both mutants reverted.
