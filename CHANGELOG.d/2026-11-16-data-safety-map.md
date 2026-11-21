### Release — the Data Safety form's answers, taken from the code (`docs/test-guides/DATA-SAFETY.md`)

- Play asks, per data type, what is collected, where it goes and whether it can be deleted. The answers now exist
  in the repository with the file and line each rests on, so the person filling the console form can check a row
  by opening a file instead of trusting a summary.
- The page records the retention windows that already govern the data (`LocationPing` 30 days, raw events 90,
  rollups 365 — `lib/usageModel.ts`), that social previews are AES-256-GCM at rest (`lib/snippetVault.ts`), that
  deletion runs through `eraseChildData()` and a password-confirmed public link (`routes/account.ts`), and that
  `ConsentRecord` is the consent evidence.
- It also records the **flavour split** that decides the form: SMS and call log are Full-only
  (`src/full/AndroidManifest.xml:12-17`) because Play's policy has no exception for monitoring apps, and
  notification access is Full-only too — so the Play build declares neither.
- **Nobody has signed it.** It is written for review and says so; §4 lists what it cannot settle (processor
  wording, the `full` build's own declaration, acceptance by review).
