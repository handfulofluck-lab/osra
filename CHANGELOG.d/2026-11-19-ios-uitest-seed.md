### iOS — a Debug-only launch seed, so the parent-PIN screens can be tested without pairing (#739)
- KP01's screen half could not run: `ParentPinViews` only appears once an identity is stored, and the only way to
  one is a real pairing against a server. `UITests` now pass `-OSRAUITestSeed pin-setup` to reach it.
- **The seed exists only in Debug.** `App/UITestSeed.swift` is entirely inside `#if DEBUG` and the call site is
  guarded the same way, so Release carries neither the argument string nor the type. CI does not take that on trust:
  `Build & Test iOS Agent` now greps the built Release binary with `strings -a` for `OSRAUITestSeed|uitest-seed` and
  fails the job if either appears.
- **It cannot point anywhere real.** The fake identity's base URL is `http://127.0.0.1:9` — the loopback discard
  port, never this build's server, staging, production or anything from `OSRA_API_BASE`. It holds a token that no
  server accepts, no HMAC secret, and is written only to the simulator's Keychain and app group.
- **It never stands in for the parent PIN.** No PIN is written, and a UI row sets one and then asserts that a gated
  action still asks for it.
- Three UI rows: the seed lands on the PIN setup screen; an empty and a mismatched PIN are both refused with the
  Bureau's line; and a gated action still prompts for the PIN under the seed.
- Verified: CI only — there is no Xcode on this PC, so the first execution of these rows is the pull request. The
  Release-binary check's exact command is named in the PR body, as Ahmed asked.
