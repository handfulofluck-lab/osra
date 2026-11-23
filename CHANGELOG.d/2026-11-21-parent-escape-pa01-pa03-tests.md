### Tests — child-escape catalogue rows PA01 and PA03, parent app (#738)

- `test/escape_pa01_app_lock_pending_test.dart` records the app-lock row as **pending** with its reason:
  it is a maintainer product decision (#742), and a test that invented the feature would be worse than none.
- `test/escape_pa03_reauth_dialog_test.dart` pins the re-auth dialog's contract that every destructive action
  depends on: cancel returns no proof, an empty proof is refused in place, a password is returned to the
  caller, and an Arabic-Indic authenticator code is normalised to ASCII.
- The empty-proof guard was mutated (guard removed) and the intended row failed; the file was reverted.

Tests only; no user-visible behaviour changes.
