# 0036 — iOS app groups chosen on the child phone, behind a parent PIN

- **Status:** accepted (2026-11-11)
- **Issue:** #372 (roadmap 5.5), from the iPhone 13 run of #550
- **Deciders:** Claude (architecture), Ahmed (security + testing); built by Ahmed

## Context

On the iPhone 13 (11 Nov), a parent block by bundle id worked, but iOS **hid** the app instead of showing the
OSRA shield, so "Ask parent" never appeared. The reason is the Screen Time API itself:

- `ManagedSettings` shields only **tokens**, and tokens come only from Apple's `FamilyActivityPicker`.
  `Application(bundleIdentifier:).token` is nil for any app the picker has not returned, so our bundle-id rules
  only reach `store.application.blockedApplications`, which hides the app.
- Tokens are **opaque**: the app cannot map one to a bundle id or a name (`Label(token)` draws the name, but the
  app cannot read it), and they are useless off the phone. The server can never learn which apps a token is.
- `TokenResolver.applicationTokens` returned *every* picked token for any rule, whatever bundle ids were asked
  for. Nothing wrote a selection yet, so it never fired, but it would have shielded the wrong apps.

The parent app is Flutter and many parents use Android, so the picker cannot need a parent iPhone.

## Decision

1. **The picker runs on the child phone, behind the parent PIN.** The parent makes **app groups** there: a label
   they type ("Games") and a picker selection (apps, categories, websites). Each group has a random UUID made on
   the phone. Groups live in the app group (`appGroups.v1`), where the extensions read them.
2. **A blocked group is shielded, not hidden.** Its tokens go to a `ManagedSettingsStore` of its own
   (`appGroups`), so a rule sync never overwrites it and shields from both stores add up. iOS then shows the OSRA
   shield with Ask parent (`POST /v1/alerts/internal`), for apps, categories and websites.
3. **Bundle-id rules stay on the hide path.** Hiding is the stronger block, and dropping it would silently
   unblock apps on phones already paired. In PR B the parent app labels those rules "hidden on iPhone".
4. **The parent PIN follows ADR-0010 to the letter**, as on Android: 4–8 digits; never all one digit or on the
   weak list; PBKDF2-HMAC-SHA256, 120,000 iterations, 16-byte random salt, stored as
   `pbkdf2$<iterations>$<saltB64>$<hashB64>` (Android's format) in the Keychain; a constant-time compare. Both
   suites read `docs/test-vectors/parent-pin.tsv`. It is **set on the phone at pairing** (a phone paired before
   this build is asked once), so no PIN or hash ever exists on the server. It gates the groups screen and
   re-pairing. After five wrong PINs it locks for 30 s, doubling per further wrong PIN up to an hour; nothing is
   ever wiped. A reinstall clears it with the other orphaned Keychain items. iOS accepts ASCII digits only (the
   number pad); Android's `isDigit` also accepts other scripts' digits, which no PIN pad there produces.
   **Forgotten PIN:** out of scope here; iOS will follow whatever Android adopts.
5. **The server learns a group by id and label, with counts only** (apps, categories, sites), never app names,
   bundle ids or tokens. The label is child-phone input: cleaned on the phone (trimmed, control characters
   dropped, whitespace folded, 40 characters at most) and again on the server, which never logs it.

## Order

- **PR A (iOS only):** the PIN, the groups screen and picker, the per-group store and shield, the
  `TokenResolver` fix. Groups stay on the phone and are **not reported**: the ADR-0034 capability report has a
  strict schema, so a `groups` field sent before the server knows it would be refused and lose the whole report.
- **PR B:** the group vocabulary in `packages/shared-types` and the API's strict schema first, then the phone's
  report, the parent app's group rows, and rules by `groupId` (block). Bundle-id rules marked "hidden on iPhone".
- **PR C:** per-group daily limits through `DeviceActivity` thresholds.

## Consequences

- A reinstall empties the app group container, so groups must be made again; a Screen Time reset can leave a
  group with no tokens, which the screen shows as "Nothing chosen" (and PR B reports as zero counts).
- The groups are only as safe as the PIN and Screen Time authorization; removing that authorization in Settings
  is the parent's control, as on any FamilyControls app.
