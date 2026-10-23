### Repo — Firebase credentials cannot be committed, and a merge resolution is checked for what it dropped
- **`.gitignore`** now excludes `google-services.json`, `GoogleService-Info.plist` and `*firebase-adminsdk*.json`.
  None of them was ignored before, and this repository is public: the Firebase project exists as of 2026-10-23 and
  the first agent to drop a service-account JSON into a checkout would have found it stageable. The key itself lives
  outside every checkout and reaches the API through Secrets Manager.
- **`AGENTS.md` §5a** records how to resolve a conflicted merge, because three resolutions on 2026-10-23 kept the
  markers out and still deleted another PR's work (`docs/ROADMAP.md` row 3.3 lost #312's Android paragraph;
  `docs/SPEC.md` went back to calling that screen unbuilt). No suite reads prose, so all three were green. The rule:
  for every file a merge reported as conflicted, check for markers **and** run
  `git diff --word-diff origin/main -- <file>`, which must show only your own change.
- **`AGENTS.md` §3** now requires the mutant beside any gate or assertion about a gate. Five checks in one night could
  not fail — a history test that read whatever the route returned, a probe check asserting a tautology, a `429` rule
  that aborted instead of failing, a write-count test blind to an unnamed mock method, and a manifest assertion whose
  `getAttribute` returns `""` for a missing attribute.
- **`docs/TESTING.md`** records the fresh-worktree trap: build `@familyshield/crypto` and `@familyshield/shared-types`
  before the API suite, or 18 of 39 files fail to *load* (measured on `main@78cca79`: 235 of 510 tests collected).
