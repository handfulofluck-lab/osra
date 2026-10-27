### Parent app — a duplicate ARB key stopped one message from being the message it declares (#423)
- `mfaResetWitnessRequired` was defined **twice** in both files with two different sentences. `jsonDecode` keeps the
  last, so a parent refused with `409 witness_required` was told *"Enter the 8-digit code."* instead of *"The witness
  step has not been completed yet."* The prompt keeps its own key now, `mfaResetWitnessEnterCode`, and the failure
  message is the one `mfa_reset_messages.dart` has always meant to show.
- `familyLoadFailed` was defined twice with identical text (added by #420). One definition remains, the one that
  carries the `@familyLoadFailed` placeholder metadata.
- A new row in the `ARB completeness` group fails on **any** repeated top-level key in either file, reading the raw
  text because every existing gate reads it through the parser that hides the duplicate. Mutant, run and recorded:
  on the pre-fix tree the row names `familyLoadFailed` and `mfaResetWitnessRequired` in both files; with one key
  injected into the fixed tree it names that key.
- `docs/TESTING.md` §6 gains both traps: the silent duplicate, and the `re.sub` replacement that writes a physical
  newline into a JSON string (which cost a rebuild of both ARBs on #421).
