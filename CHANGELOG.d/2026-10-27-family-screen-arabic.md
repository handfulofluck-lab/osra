### Parent app — the family screen speaks Arabic (3.1 remainder, #419)
- 27 keys cover every string on the screen: the title, the parents and pending-invite sections with their empty states,
  the invite and revoke actions and their snackbars, the whole invite dialog (email and role labels, the two role names,
  permissions heading, the test-build token explanation, send/copy/done/cancel) and the token-copied confirmation.
- The two `Failed to load …` sites now route through `readErrorText`, so a guardian whose invite lacks the permission sees
  the owner sentence instead of a raw error — the one behaviour change inside a copy task.
- A new Arabic RTL row in `localization_test.dart` renders the screen at 320×568 with no overflow, which is the first time
  this screen's Arabic has been rendered at all.
- **Karim's review of the Arabic is the acceptance and stays open** — this adds 27 strings to that queue rather than
  closing it. `family_map_screen.dart`'s 14 strings are the rest of #419 and are not in this change.
