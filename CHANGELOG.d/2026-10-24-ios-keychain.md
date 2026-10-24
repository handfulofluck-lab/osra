### iOS child agent — the device token and HMAC secret are in the Keychain (5.5 PR B, #372)
- `AgentIdentityStore` now stores `deviceToken` and `hmacSecret` as Keychain generic-password items
  through `KeychainSecretStore`, no longer as plaintext app-group `UserDefaults`. The items have
  service `dev.familyshield.agent`, the access group `group.dev.familyshield.agent`, and accessibility
  `AfterFirstUnlockThisDeviceOnly`:
  - the monitor and shield extensions can read them while the phone is locked;
  - no backup carries them, so a restored phone re-pairs.
- The non-secret ids (server address, child, device and family ids) stay in app-group `UserDefaults`.
- A phone paired by an older build stays paired. `load()` and `hmacSecret()` (which `AlertReporter`
  calls, in the extensions too) move the old plaintext keys into the Keychain, and delete them only
  once the Keychain holds them. A refused Keychain write loses nothing and is retried on the next read.
- `save` reports failure when the Keychain refuses a secret, and leaves no half-written identity.
- Tests, in two places:
  - `AgentIdentityStoreTests`, in the SwiftPM target, use an in-memory store: secrets kept out of
    `UserDefaults`, clear, migration from the app and from the extension path, a stale plaintext copy,
    and a refused write. CI showed the unsigned SwiftPM bundle cannot use the simulator Keychain
    (`-34018`).
  - `OSRAAgentHostedTests` is a new target in `project.yml`, run inside the simulator app. It tests the
    real Keychain with the production access group, and checks the item's accessibility and that an
    overwrite leaves one item.
- Simulator builds are now ad-hoc signed (`CODE_SIGN_IDENTITY "-"`, no team), so the app carries its
  entitlements. Device builds stay unsigned in CI.
- Not checked yet: an extension reading the item the app wrote, on a signed device build (5.1).
