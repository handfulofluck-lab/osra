### Child and parent apps — secure storage fails closed and the built-in server field is hidden outside debug (#638, osra-security#8 F2/F3)
- Ahmed's threat-model review supersedes the #563 plaintext fallback. When the child's encrypted store still will not
  open after the existing two retries and the delete-and-reopen, `SecureStore` no longer opens or writes the plaintext
  fallback. It deletes the legacy plaintext file and returns an in-memory `NoopSharedPreferences`, so the phone reads
  as unpaired and shows the re-pair notice — no secret is ever written in plaintext.
- The fail-closed state is exposed as `AgentSettings.secureStoreUnreadable()`. The next pairing claim sets
  `dataCleared` on that flag (or the original `pm clear` signature), whatever the device-admin tier, so the parent's
  Allow records the `agent_data_cleared` tamper alert server-side. No unsigned local alert is enqueued — an unpaired
  phone's `postInternalAlert` would be unsigned and answer 401.
- Pairing now fails closed too: `savePairing` retries a recovered store, writes the secrets, reads the device token
  and the HMAC back, and only then updates DataStore and the in-memory caches — a no-op or partial write can never
  report the phone paired or start services. Legacy DataStore migration keeps the plaintext copy until the secure
  copy reads back, so a failed secure write never deletes the only credential. The unreadable flag is in memory, not
  persisted, and clears when a later open (or `reopenIfUnreadable`) finds encrypted storage working again.
- Parent app (osra-security#8 F3): the login server field is hidden outside debug when the build is locked to its
  built-in server, so a store build cannot edit or redirect the server; debug builds keep the field visible and
  locked for testers, and an unlocked build stays editable.
- Tests: `SecureStoreOpeningTest` drives `SecureStoreOpener` with fault injection (no fallback opened, empty store);
  `SecureStoreReopenTest` drives the same `SecureStore` from a fail-closed open to a later healthy open;
  `SecureStoreWriterTest` drives the verified write/migration rules including a dropped-HMAC partial write;
  `NoopSharedPreferencesTest` exercises the real fail-closed store; `DataClearedClaimWiringTest` pins the claim flag,
  the notice, the save guard and the no-unsigned-alert rule.
