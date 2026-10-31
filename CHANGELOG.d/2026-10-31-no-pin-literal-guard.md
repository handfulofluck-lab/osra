### CI — a PIN-shaped literal in docs, scripts or workflows now fails the build (#151)
- **The exposure this answers:** the repository is public and the test family's parent-app PIN sat in five
  places on `main` for days. That PIN opens *Remove protection* and *stop ring* on the paired phone, so the
  only thing that actually closes it is a rotation — which git history cannot undo.
- **The guard:** `scripts/check-no-pins.mjs` scans `docs/`, `scripts/`, `.github/` and `README.md` for a
  standalone 4–8 digit number within 16 characters of the word `PIN`, in either order, and exits 1 with
  `file:line`.
  - It is deliberately narrow about what counts: a token that is part of an identifier (`ADR-0010`,
    `TR-09`) is not a value, `0000` is the desktop agent's **refused** old default that the docs must name
    to explain #140, and a placeholder (`<app-PIN>`) has no digits.
  - It is deliberately wide about where it looks: prose is where this leaked, in five files, over weeks —
  so the scan covers `docs/`, `scripts/`, `.github/`, `infra/`, `CHANGELOG.d/`, `README.md`,
  `CHANGELOG.md` and `AGENTS.md`.
- **Wired into `workflow-lint` beside the docs-links check, self-test first.** Eleven fixtures, each a
  decision: a value after the word, before it, after an *earlier* PIN on the same line, the refused
  `0000` default, a placeholder, an identifier (`ADR-0010`), a date and time — and four negatives. Two of
  the original negatives never contained the word `PIN` and so could not fail; both now do. A guard that is green because it
  is broken is the failure mode this repository has paid for before.
- **Mutant, run before pushing:** a planted `The test family parent PIN <six digits> …` line in `docs/TESTING.md`
  → `docs\TESTING.md:1235: a 6-digit number next to the word PIN (#151)`, exit 1; reverted → exit 0. The
  fixture value inside the script is composed (`["48","2613"].join("")`) so the guard does not flag itself.
- **State of the repository at this commit:** the scan is clean — the five published values are already
  `<app-PIN>`/`<device-PIN>`. **The rotation is the remaining step** and it is a phone job: change the test
  family's app PIN on the Flip4 through the app's own flow and keep the new one outside the repo. Until
  that happens the old value stays in git history, which is why this PR does not close #151.
- Items 2–4 of the issue: the redaction and the two ledger debts were **already recorded** on `main`
  (`VERIFICATION-LEDGER-2026-10-18.md:37-38, :91, :141-144`); this PR adds the guard that stops the next one.
