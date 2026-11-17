### Verified gate — one self-test row per server Arabic path (#846 follow-up)
- #904 added five anchors to `ARABIC_PATHS` (`consentCopy.ts`, `htmlPage.ts`, `linkPages.ts`, `account.ts`,
  `digests.ts`) and its own verifiers noted the gap it left: only one of the five had a self-test sample, so
  deleting a pattern made the selftest merely shorter (294 → 292 cases) instead of failing. A count cannot
  tell a shorter suite apart from a passing one.
- `scripts/verified-gate-policy.mjs` now carries one sample per new path in the Arabic sample list. The
  selftest is 304 cases, and each of the five fails **by name** when its pattern is removed — measured, not
  assumed: dropping `/^services\/api\/src\/routes\/account\.ts$/` prints
  `FAIL Arabic path services/api/src/routes/account.ts: no Arabic line: want false, got true`, and restoring
  it returns `304 cases pass`.
- No pattern, tier or signer rule changed: this only makes an existing rule falsifiable.
