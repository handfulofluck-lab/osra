### User-visible OSRA — remaining FamilyShield-named surfaces now say OSRA (#608)
- The GDPR export filename is `osra-export-<familyId>.json` (was the old familyshield-namespace name).
- The demo parent signs in as `demo@osratech.com`. Locally the password is the public non-production
  default in `services/api/scripts/seed-password.ts` (never printed); against staging it is read from
  the `osra-staging/demo-password` secret.
- Windows and macOS user-visible data folders are `OSRA`, with a one-time migration from `FamilyShield`
  that preserves pairing.
- Windows test certificate: only newly generated roots use the `OSRA Test Root` subject; existing PFX
  files and trust entries are deliberately unchanged.
- Internal package/namespace/header/target names stay unchanged, so already-paired devices keep working.
- Adds `scripts/check-user-visible-brand.mjs` and a `workflow-lint.yml` step (`--selftest` then the real
  scan) that fail any tracked or untracked repo file still carrying a pre-OSRA user-visible form.
- Seeding an old-seed database renames the existing demo parent to the new address, preserving its id
  and password hash. Two runs leave one owner rather than adding a second owner beside the old address.
- Test-data cleanup refuses to apply unless exactly one current demo parent exists. It deletes only
  explicit test-owner families, non-Alex demo children, and empty `QA Family` orphans; legitimate
  non-test and reviewer families are preserved. The old `NOT IN` predicate is gone.
- Three real-Postgres regression tests proved all three defects before the fix and pass after it. The
  Linux API job now requires an isolated Postgres service for these tests. The brand guard permits the
  legacy address only in named migration constants in the seed and its fixture, not in user-facing text.
- Verification evidence (suite runs): API 60 files / 899 tests; Windows desktop 242 tests; macOS
  migration 6 tests; Android Play 988/988 and Full 988/988; Flutter 623 tests with `flutter analyze`
  clean; brand guard self-test 60/60 and real scan green; workflow lint 19 files clean; docs-links
  self-test 17/17 and 142 links in 356 Markdown files clean.
- Still unverified: the `net8.0-macos` app build and iOS/macOS device behaviour (not verified on a Mac).
  Not merged, and no independent Claude verification is claimed.
