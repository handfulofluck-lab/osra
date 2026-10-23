### Docs — the 16 Oct KCL readiness assessment is in `main`; four superseded branches deleted (roadmap 0.5)
- `docs/QA/KCL-2026-10-16/` now holds the external architecture lead's readiness assessment (README, the Android audit,
  the API/AI/parent-app audit, the iOS/Windows/macOS audit, and the competitor landscape). **Copied, not merged** —
  `git checkout 3676a9d4 -- docs/QA/KCL-2026-10-16/` — because merging would put that branch's commit history and author
  metadata into `main` for five documents. Blob hashes are unchanged and recorded in the discussion log, so a reviewer can
  check byte-identity rather than take it on trust.
- **Four superseded branches deleted** on the maintainer's word (17:01:08Z, "Do both"): `docs/adr-0030-region-and-lifecycle`
  (#299), `docs/adr-0028-prod-account` (#292), `docs/roles-antigravity-silent` (#214) and `qa/verify-track12-2026-10-12`
  (#36). Each tip was re-read with `git ls-remote` and matched the value recorded before deletion; every one is listed
  `name sha` in `docs/QA/DISCUSSION-LOG.md` and restorable with `git push origin <tip>:refs/heads/<branch>`.
- The `KCL` branch itself is deleted as the **last step after this merges**, since it is the source of the copied files.
  That is the final item on roadmap 0.5.
