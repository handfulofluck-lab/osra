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
- New `SecretStoreTests` run on the simulator Keychain. They cover write, read, overwrite and delete;
  secrets kept out of `UserDefaults`; clear; migration from the app and from the extension path; a
  stale plaintext copy losing to the Keychain value; and a refused write.
- Not checked yet: sharing the items between the app and its extensions. That needs a signed build (5.1).
