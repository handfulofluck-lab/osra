### Mac step (ii): the OSRA Agent daemon pairs, syncs rules and sends heartbeats (#775)
- `apps/child-ios/MacAgent/` is a new Swift package for the Mac's root launch daemon (`osra-agent`, launchd
  label `com.osratech.agent`, `RunAtLoad` + `KeepAlive`). It depends on the shared Swift package and copies
  nothing from it: pairing, the HMAC signer, the identity store, rule sync, the command drain and device
  removal are the iPhone's code. The one shared-package change is additive: `PairingClient.claim` takes a
  `ClaimDevice` (default: the iPhone, unchanged), so the Mac pairs as `platform: "macos"` with its capability
  report and `X-OSRA-Client: agent-macos/…`.
- Pairing is the 6-digit code only (ADR-0041 D5): the server is one constant, the staging API, with no field
  or option to change it. The device token and HMAC secret go into the System keychain; ids and rules into
  root's preferences.
- Nothing says "paired" until the server has accepted a request signed with the device's HMAC secret
  (`SecretProof`). A refused secret is `secret_refused`, and the daemon then sends nothing as the device.
- The cycle: a command poll every 60 s (a rule change arrives as `rules_updated` within one poll; commands the
  Mac cannot run are acknowledged `failed: not_supported`), and a rule sync plus heartbeat at start and every
  15 minutes. The Mac enforces nothing in this step, so every planned feature is reported `unavailable` and no
  applied rules version is sent.
- `pair --child-user <account>` warns on the command line when the child's macOS account is an administrator
  (ADR-0036 rule 4). The parent-app warning needs a server capability and Bureau wording, and is not here.
- No screen and no family-facing text. The log (subsystem `com.osratech.agent`) carries fixed words and
  numbers only.
- CI: the existing `macos-core` job also lints the launchd plist and builds and tests the new package; path
  filters, triggers and the concurrency group are unchanged. The shared package's macOS test count goes from
  223 to 225 (two claim-payload tests).
- **Not verified where it was written:** the code was written on Linux, where Swift for macOS cannot build.
  The first compile and test run is this PR's macOS CI and the test Mac; the real-Mac rows (pair with staging,
  rule change, killed daemon, wrong HMAC key, secret unreadable by a standard user) are listed in
  `apps/child-ios/MacAgent/README.md` and are still owed.
