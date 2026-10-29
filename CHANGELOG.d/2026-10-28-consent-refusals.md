### Parent app — a command refused for consent says which consent problem it is (#434)
- An enforcement command (`lock`, `pause`, `bedtime`…) is refused with `428` when consent is gone, and the body's
  `error` says which: `parental_consent_required` or `consent_jurisdiction_mismatch`. Both rendered as the wire code
  inside `Command failed: {error}`.
- `commandErrorText` now keys them on the **status plus the body's code** — a bare `428` without a known code stays
  verbatim, because it is a bug report and not a sentence we invented. The two get **different** sentences: "give
  consent again to resume" and "the family's region and this child's jurisdiction do not match" send a parent to
  different places.
- The Arabic is a placeholder shaped like its siblings (masculine `لم يُرسل`, the command in `«»`) and pinned by the
  rows, so Karim's lines change the ARB and one literal each. **English and Arabic both wait on his ruling** before
  merge.
- Mutants: removing the `parental_consent_required` branch reddens the sheet row and the unit row; collapsing both
  codes into one sentence reddens the unit row.
