### Capability report — the phone says whether it has another space (counts and kinds only)
- **What a parent will see, once ADR-0034 PR 2 and PR 3 land:** a Phone setup row such as "This phone has a
  second space for cloned apps (Dual Messenger)", or "a work profile", or "another space. OSRA may not reach the
  apps inside it."
- **Shape:** `capabilities.profiles = { others: 0..8, kinds: ("work" | "clone" | "secure_folder" | "other")[] }`
  in `packages/shared-types`, checked by the API's strict schema.
  - `kinds` is a set with at most `others` entries.
  - `others > 0` with no kinds is refused, so an unknown profile is never shown as a clean phone.
  - No user ids, names or app lists exist anywhere in the shape.
- **Optional on the wire:** a report without `profiles` keeps the stored value (`withStoredProfiles`), so an
  agent that cannot read profiles never erases what one that could said. `GET /v1/devices[/:id]` returns it as
  `setup.profiles`, or `null`.
- **Agent:** `ProfilePolicy` (pure, JVM rows) maps each user type to a kind:
  - `android.os.usertype.profile.CLONE` → `clone`, the type the Flip4 capture showed for Dual Messenger's
    user 95 on SDK 36;
  - `…MANAGED` → `work`;
  - anything unreadable, or anything below API 35, → `other`.
  - `secure_folder` stays unmapped until a capture shows its type.
- **Not sent yet:** `ProfileReader` reads `UserManager.getUserProfiles()`, but nothing calls it until PR 2's
  transport does. That a normal app sees user 95 there is still to be confirmed on the phone.
- **Also:** `UsageReportCountersWiringTest` pins that one `recordForeground` call feeds both the daily limit's
  counters and the rows the parent's usage report is built from. That is why time in a cloned app is counted
  in both.
- **Strings:** three Phone setup rows in `app_en.arb` / `app_ar.arb`. The Arabic is a draft for Karim's review.
