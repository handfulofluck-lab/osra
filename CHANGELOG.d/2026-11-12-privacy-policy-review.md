### Site — privacy policy corrected after a legal read (roadmap 5.2)

The policy at `site/privacy/` was read claim by claim against the apps and server on main before it goes public.

- It now covers the App Store apps as well as Google Play, and has an "On an iPhone" part saying what OSRA Kids sends there (location, blocks and requests, device information) and what it cannot do (no chat text, no web filtering, no app names).
- The note to the child no longer says OSRA "does not read your texts" beside a sentence about chats; it says which chats can be read on Android and that none can on an iPhone.
- Added: the legal grounds, the Apple Push Notification service as a provider, that push, map and email providers may handle data outside the EU, the 12-month record of a two-step sign-in reset, the full list of rights with a one-month answer, and that alerts are raised by fixed rules.
- Backups and server logs: "at most 90 days" (maintainer's decision, 12 Nov), on the policy and on `/delete-account`. Production infrastructure must be set within it: RDS automated backups cannot exceed 35 days, and the log groups need `retention_in_days` of 90 or less.
- New page `site/terms/` (terms of use), asked for by the maintainer: no warranty, and the user gives up claims for compensation, damages or reimbursement unless they prove harm caused on purpose, as far as the law allows, with the carve-out for rights the law does not let anyone give up. Linked from every footer, the home page and the policy. **The apps do not yet ask a parent to accept the terms at sign-up; until they do, the terms bind nobody.**
- Both pages name the person responsible and a postal address, and the terms are governed by UAE law as applied in Dubai, keeping any consumer protection the user's own country does not let them sign away (maintainer, 12 Nov).
