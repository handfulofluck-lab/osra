### iOS child agent — asks for Screen Time, a location button that always works, and "OSRA Kids" (5.5, #372)
- The Status screen gains a **Screen Time** section: the FamilyControls status (Off / On / Not allowed) and a
  "Turn on Screen Time" button while it is not approved, which finally calls `requestAuthorization()` (it had no
  caller, so nothing a parent set was enforced on iOS). An approval re-runs the rule sync at once; the status is
  re-read when the app returns to the foreground. The status goes through `ScreenTimeAuthorizing`, so tests drive
  all three states without FamilyControls.
- The location button opens Settings when the permission was denied or restricted, or once the one-time Always
  prompt was used (the flag is kept in the app group); its label says which: "Allow location" or "Open Settings".
- The home-screen name is **OSRA Kids** (`CFBundleDisplayName`, `en.lproj`); the Arabic name «أسرة للأطفال» is
  pending Karim's approval. `check-app-bundle.py` fails the build on any other English name.
- `docs/TESTING.md` §5k: iPhone setup, including registering the app group in the developer portal by hand.
