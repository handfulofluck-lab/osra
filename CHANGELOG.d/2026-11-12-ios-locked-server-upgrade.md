### OSRA Kids for iPhone — the built-in server holds across an upgrade (#634 G1)
- **Before:** a build with a built-in server (`OSRAAPIBase`) locked the pairing screen, but an install over an
  older install kept that install's pairing, even with another server.
- **After:** at launch, a build with a built-in server clears a stored pairing with any other server, together
  with its rules and its parent PIN, and shows the locked pairing screen. The parent sees the device go unpaired.
  A pairing with the built-in server is kept (the host's case, a trailing slash and an explicit `:443` don't
  matter), and a build without a built-in server changes nothing.
- **Every reader goes through the lock**, the extensions included: `AgentIdentityStore.storedServer()` returns
  nothing for a stored server other than the built-in one, and both `load()` and the extensions' alert sender use
  it. So nothing is sent to the old server even before the app is first opened. The extensions now carry
  `OSRAAPIBase` too, and `OSRA_API_BASE` became a project-wide build setting.
- Rows (`AgentIdentityStoreTests`): another server is cleared (ids, Keychain secrets, then the PIN by the orphan
  sweep), the same server is kept, no built-in server changes nothing, `sameServer` cases, the app runs the
  lock before the orphan sweep, every reader refuses the other server, and the extensions read through the lock.
