### Docs — the roadmap's status column is true again, row by row (#342)
- **Six rows claimed work was unmerged when it had shipped.** Each cited PR was checked on `origin/main` before this change,
  and every claim is now a merge sha: 3.2 (#153 `69d1575`, #179 `df7c89e`, #189 `025be5b`), 3.4 (#201 `96d0d2c`),
  3.5 (#142 `f2437a9`), 3.7 (#191 `675a118`), 3.8 (#145 `2e6b5aa` + #203 `01c98a9` + #204 `72beb78`), and 3.3, whose five
  `feat/297-*` branches were each called "not merged" and each merged (#305 `afc3ea3`, #307 `68dd367`, #309 `1a9efab`,
  #311 `129b2ca`, #312 `78cca79`, #313 `0d5158b`, #314 `cfca0c9`).
- **Three rows were ✅ without their acceptance:** 1.4 (Firefox and in-app WebView never run, TR-14), 1.8 (Play pre-launch
  report not run, release HTTPS enforcement unmeasured) and 2.6 (no WhatsApp→scan event ever produced) are now 🔵, with the
  missing measurement named in each cell. A tick beside an unmet acceptance is the thing this column exists to prevent.
- **Four rows were accurate but stale in a detail:** 0.4 named `start-backend.bat`, which is not in the repo (the committed
  artefact is `docs/test-guides/start-backend.example.bat`); 2.7 said F5 was "on `ahmed/2.7-hook-independent-sessions`" when
  it merged in #338 (`8214c6c`); 3.6 said WO-03 still owed the independent record when TR-57 carries it; 4.1 said "9 offline
  tests" where the file now holds 12.
- **5.8 was described as "no bucket exists there, nothing is applied".** Since then Stockholm's state bucket and `base` are
  applied, the certificate is validated, the HTTPS stack served the 1.5 push row, and the guards merged in #339. The row now
  says that, and names what the acceptance still needs.
- The Phase 3 line in "Progress at a glance" said 1 / 9 merged; it now lists the eight merged rows with their shas, the one
  acceptance still open (3.1's native-speaker review) and the one row blocked externally (3.9, Apple entitlement).
- **From the review (#342):** the "Progress at a glance" table now matches the rows beneath it — dated 2026-10-23, Phase 0
  at 6/6, Phase 1 at 9/9 with 1.5 measured (TR-95) and the acceptance open on 1.4/1.8, Phase 2's push half measured on
  Android and open on iOS, Phase 3 naming the timed first-run test, Phase 5 at 0/8 with 5.8 in progress. Five cells also
  contradicted their own status and are fixed: 1.4 said "acceptance not closed" twice, 3.2 repeated its own clause, 3.3
  still said "author-run only, unmerged" under a heading that says #305 merged, 3.8 named two branches that are #203 and
  #204, and 1.5's "no `docs/QA/` record" is now **TR-95**, supplied by Claude from his own run — the record belongs to
  whoever measured it.
