### API — the capability report accepts the iPhone's app groups (5.5 PR B1, ADR-0037, #372)
- `groups` in the capability report: id (UUID), label (1–40 characters, checked again on the server, never logged)
  and counts of apps, categories and sites. No app names, bundle ids or tokens. iPhone only, at most 20, with its own
  8 KB cap outside the report's 4 KB. A report without groups keeps the stored ones; `DeviceSetup.groups` shows them.
- Lands before any phone sends the field, so an early report is never refused. New `capabilities-groups.test.ts`.
