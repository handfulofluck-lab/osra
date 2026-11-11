### iOS child agent — app groups behind a parent PIN, shown the OSRA shield (5.5 PR A, ADR-0037, #372)
- A **parent PIN** is set on the phone at pairing (asked once on phones paired earlier), with Android's rules and
  storage format: 4–8 digits, no repeated or weak PINs, PBKDF2-SHA256 at 120,000 iterations in the Keychain, a
  constant-time compare; five wrong PINs lock it for 30 s, doubling to an hour, wiping nothing. It gates the new
  **App groups** screen and re-pairing, and a reinstall clears it.
- **App groups:** the parent names a group and chooses its apps, categories and websites in Apple's picker on
  the child phone. A blocked group is shielded from its own store, so iOS shows the OSRA screen with Ask parent
  instead of hiding the app. Bundle-id rules still hide their apps. Groups stay on the phone for now (PR B
  reports them by id, label and counts).
- `TokenResolver` no longer returns every picked token for any rule; the unused `SelectionStore` and
  `applySelection` are gone. The shield also covers apps and sites blocked through a category.
- Shared PIN cases in `docs/test-vectors/parent-pin.tsv`, read by `ParentPinTests` (iOS) and
  `ParentPinSharedCasesTest` (Android). ADR-0037 records the design and the A/B/C order.
