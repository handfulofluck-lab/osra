### Child Android — the unlink half-confirmation survives a process death (#1162)

`UnlinkPolicy` accepted a persisted first answer, but `AppModule` still built it without the store, so a process death between the two `device_revoked` answers started the confirmation over. The policy is now wired with its persisted store, and writes go through a single serialised dispatcher so two answers cannot interleave.

The behaviour a parent sees: a revoked phone unlinks on the second confirming poll, even if the child app is killed or the phone reboots in between — the first answer is no longer lost. No UI or copy change. (Wording corrected on Ahmed's security re-key, 04:46: "within the first poll" read as if one answer were enough; the code still requires two.)

Verified with `UnlinkPersistenceWiringTest` and `UnlinkPolicyTest`; the security key and the cross-family receipt are on PR #1164.
