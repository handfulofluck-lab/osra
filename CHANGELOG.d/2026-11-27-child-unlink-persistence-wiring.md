### Child Android — the unlink half-confirmation survives a process death (#1162)

`UnlinkPolicy` accepted a persisted first answer, but `AppModule` still built it without the store, so a process death between the two `device_revoked` answers started the confirmation over. The policy is now wired with its persisted store, and writes go through a single serialised dispatcher so two answers cannot interleave.

The behaviour a parent sees: a phone that has been revoked unlinks within the first poll that sees it, rather than restarting the wait after the child app is killed or the phone reboots. No UI or copy change.

Verified with `UnlinkPersistenceWiringTest` and `UnlinkPolicyTest`; the security key and the cross-family receipt are on PR #1164.
