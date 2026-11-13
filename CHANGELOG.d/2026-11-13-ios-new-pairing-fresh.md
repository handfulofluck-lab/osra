### OSRA Kids for iPhone — a new pairing starts clean (#691)
- **Before:** after pairing again, the Status screen could read "Not synced for 11 hours", a time carried over from
  the earlier pairing, until Sync now. The earlier pairing's rules also stayed until the first sync.
- **After:** the pairing screen saves through `AgentIdentityStore.saveNewPairing`, which first clears the earlier
  pairing's rules, last-sync time and uploaded push token. The screen reads "Not synced yet" until the first sync
  for this child.
- Rows (`AgentIdentityStoreTests`): a new pairing has no last-sync time and no old rules, and keeps the name the
  parent gave; a source row checks that the pairing screen uses it.
