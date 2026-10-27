### Push — a parent alert no longer carries the child's name or the alert text (#410, #360 server half)
- `buildParentAlertMessage(platform)` replaces the content-carrying builder, which is **deleted** rather than deprecated:
  leaving it in place is how #410 happened.
- **Android**: data-only, `data` is exactly `{ "w": "1" }`, `HIGH` priority because the app has to wake to fetch, and a
  constant `collapse_key: osra-wake` because one wake reads every unseen alert.
- **iOS**: a visible alert built from `title-loc-key` / `loc-key`, plus `content-available: 1` and the same data. `aps`
  carries no literal text, so the words come from the app bundle.
- The child-device wake is unchanged: it displays nothing, which is a different rule.
- Tests: the two rows that **asserted the child's name in the payload** are replaced by T1/T2 (android has no
  `notification` block, `data` equals `{ w: "1" }`, and canaries are absent from the serialized body) and T3 (iOS has
  loc-keys, no literal text). The Flip4 caught this as a duplicate notification; the tests were asserting it.
- **⚠️ not measured here:** the Flip4 row (exactly one notification, the localized one) is Claude's, and the iOS
  `PUSH_ALERT_TITLE` / `PUSH_ALERT_BODY` keys still need adding to `Runner/{en,ar}.lproj/Localizable.strings`, with
  Karim's review of the Arabic.
