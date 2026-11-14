### Site — the privacy page states the 12-month alert window (Play decision 10 B)
- **Before:** `site/privacy/index.html` §7 said alerts were kept "until the child or the account is deleted"
  and that the window was being reduced to 12 months, because alerts had no expiry in `applyRetention`.
- **After:** #571 is merged, so alerts go at 365 days. The page now says "12 months, or until the child or the
  account is deleted if that comes first", matching `docs/store/play/data-safety.md` §5.
- Also corrects the two line citations in `data-safety.md` §5 to `usageModel.ts:271` (the retention delete)
  and `:327` (the erase delete).
