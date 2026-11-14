### OSRA Kids on iPhone — the child's name, the last sync and "Sync now" on the status screen (#602 items 2–4)
- The pairing poll's 201 now carries `childName` (the name the parent typed); the phone stores it with the identity
  and shows it instead of the child id. The device id is no longer shown.
- Under "Paired": "Last synced 2 minutes ago", "Not synced yet", or, past 30 minutes, an amber "Not synced for 45
  minutes. Check the internet connection, then tap "Sync now"." (`SyncStatus`).
- A "Sync now" button does what opening the app does (drain commands, fetch and apply the rules, report), and a
  footer says plainly that a change can take a few minutes to arrive while the app is closed.
- Eight new strings; the Arabic is the Bureau's, approved by Karim on 12 Nov (12:55Z). New `SyncStatusTests`
  (5 rows), plus rows in `PairingTests`, `AgentIdentityStoreTests` and the API's `pairing.test.ts`.
