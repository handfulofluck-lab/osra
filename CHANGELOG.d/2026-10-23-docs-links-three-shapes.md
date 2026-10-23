### Tooling — the docs-link gate saw three link shapes it never checked (#324)
- `scripts/check-docs-links.mjs` is the gate behind every PR's "0 broken link(s)" line. Three shapes
  passed silently, each measured on the parent tree before the fix:
  - **an anchor into a heading-less file** — `headings.size > 0` made the *certainly wrong* case the
    one that passed (`[x](plain.md#anything)` where `plain.md` has no `#` heading: exit 0);
  - **reference-style links** — only inline `[label](target)` was scanned, so `[x][g]` with
    `[g]: docs/missing.md` was not even counted;
  - **intra-file anchors** — `[x](#section)` was skipped outright, while the code comment claimed they
    were "handled below". A table of contents pointing at a renamed heading passed.
- Fixed all three. The checker now resolves relative paths, `#anchor` targets (including `#top` and a
  bare `#`), reference definitions, intra-file anchors and root-absolute `/docs/...` links, and GitHub's
  duplicate-heading `-1` suffix. A heading-less target can no longer satisfy an anchor: the file cannot
  contain the heading, so the link is broken.
- **Three more rules from Claude's #325 review, each a real defect in the first cut:** an intra-file
  anchor in a file inside a folder resolved the containing file as `resolveTarget(file, file)`, i.e.
  `docs/docs/x.md`, so the first table of contents in `docs/` would have failed on a correct link;
  percent-encoded paths regressed because the `decodeURI` was dropped (a `My%20File.md` link broke while
  the old checker passed it); and GitHub keeps an **intraword** underscore in a slug
  (`FCM_SERVICE_ACCOUNT_JSON` → `fcm_service_account_json`) while dropping an emphasis one (`The _x_
  thing` → `the-x-thing`, both measured with `POST /markdown`). Also fixed: a valid root-absolute
  `(/docs/...)` link still failed because the inline pass claimed it and resolved it against the file's
  own folder — the extraction now classifies it once, as root-absolute.
- **A fourth rule, found by its own new strictness:** the gate used to read link syntax **inside code
  spans and fences**, where Markdown renders it as literal text. Making the three shapes stricter surfaced
  four "broken links" in this repository and all four were examples quoted inside backticks. `stripCode`
  removes fenced blocks and inline spans before scanning, so documentation *about* broken links does not
  fail the gate.
- **The gate has a self-test for the first time** — `--selftest`, 17 fixtures covering the four rules, the
  passing controls, `#top`, duplicate headings and the ignored schemes. It runs in
  `workflow-lint.yml` beside the other script self-tests. Mutants, one per rule, each measured:
  restore the `headings.size > 0` guard → `an anchor into a heading-less file is reported (#324)` fails;
  drop the reference scan, drop the intra-file branch, resolve the containing file as `resolveTarget(file, file)`,
  drop the `decodeURI`, strip every underscore, let the inline pass claim a root-absolute link, or return the text
  unstripped — each one makes exactly its own fixture fail (`16/17`).
- **The count in the summary changes** from 162 to 118 on `main`'s tree. Not a loss of coverage: the old
  code counted every root-absolute link twice (inline pass + its own loop) and never counted intra-file
  anchors at all. `checked` now means distinct link targets.
- **Evidence:** `--selftest` 17/17; the real repo `0 broken link(s) out of 118 checked in 108 Markdown
  file(s)`; the three issue repros each report a `problems` line and exit 1; `check-workflows.mjs
  --strict` 0 errors across 9 workflow files.
- **Not claimed:** this cannot catch a link that is valid but points at the wrong document — only a
  human reading it can. And `--selftest` covers the rules, not GitHub's rendering: an anchor that works
  here should work on the web UI, but that is inferred from GitHub's documented slug rules, not observed.
