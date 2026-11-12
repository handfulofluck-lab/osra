### OSRA Kids for iPhone — the built-in server holds across an upgrade (#634 G1)
- **Before:** a build with a built-in server (`OSRAAPIBase`) locked the pairing screen, but an install over an
  older install kept that install's pairing, even with another server.
- **After:** at launch, a build with a built-in server clears a stored pairing with any other server, together
  with its rules and its parent PIN, and shows the locked pairing screen. The parent sees the device go unpaired.
  A pairing with the built-in server is kept (the host's case, a trailing slash and an explicit `:443` don't
  matter), and a build without a built-in server changes nothing.
- Rows (`AgentIdentityStoreTests`): another server is cleared (ids, Keychain secrets, then the PIN by the orphan
  sweep), the same server is kept, no built-in server changes nothing, `sameServer` cases, and the app runs the
  lock before the orphan sweep.
