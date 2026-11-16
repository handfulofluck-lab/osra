### Parent app — a direction-mark row for the allowed-domain list (#794)
- `localized_list_test.dart` now types a leading right-to-left mark (U+200F) before `a.com` into the
  allowed-domain field and requires `a.com` in the PUT body, mirroring the existing blocked-domain row.
  Antigravity's after-merge review of #799 noted that `allowedDomains` used the same helper without a
  row of its own; this closes that test gap. No product code changes.
