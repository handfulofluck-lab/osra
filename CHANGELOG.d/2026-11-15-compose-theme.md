### One Compose theme, generated from the design tokens (#728)
- The child agent gets the theme its screens will be drawn on: `OsraTokens` is generated from
  `docs/design/tokens.json` by `scripts/gen-android-tokens.mjs` (28 colours in two themes, per-theme radii, spacing,
  sizes and the nine-step type scale), and `OsraTheme` maps it onto Material 3 — colour scheme, typography and
  shapes. No screen changes in this part; the pairing screen follows.
- **The generator is the guard.** `node scripts/gen-android-tokens.mjs --check` exits 1 when the Kotlin no longer
  matches the design file, and `workflow-lint` runs it and matches its summary line — so a token changed without
  regenerating is a red job rather than a wrong colour on a phone. The site pages already have the same guard on the
  same file.
- **Two gaps stated, not hidden:** the IBM Plex families are named but not bundled (the files and their OFL licence
  belong in the PR that draws the first screen), and `cardBorder` is the design's `transparent` in the light theme.
- Verified by JVM tests only: `OsraThemeTokensTest` (five rows on the mapping) and `PairingScreenStateTest` (the
  screen's rules). **Not verified on a handset** — no screen uses the theme yet.
