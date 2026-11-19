### Parent app — sign-up page: the Bureau's conditions, and a sentence a parent can act on (#846, #862)
- The create-account scroll now ends below the button: the content's bottom padding is the safe-area
  inset plus 24, so at the largest text the whole button is visible with room under it (UI/UX Bureau
  condition 1).
- Every field carries `helperMaxLines: 3` and `errorMaxLines: 3`, so "At least 12 characters." and the
  family-name helper are never cut with an ellipsis at 320 px / 200 % text (condition 2).
- `onboardingNoNetwork` no longer names a server address: English is "Couldn't connect to OSRA. Check
  your internet connection, then try again.", Arabic is the Arabic Language Bureau's line of 17 Nov,
  copied byte for byte. The string is shared, so the fix reaches every screen that shows it
  (condition 4).
- A test row pins that the consent link labels keep their spaces (the parser copies them out of the
  copy's markdown and rewrites nothing), so an underscore can only come from the copy or a stub
  (condition 3).
- Verification: no Flutter SDK on the authoring host, so `flutter test` and `flutter analyze` are CI
  evidence on the PR. The Bureau's re-pictures (SE 3 at the largest text, one 320/200 % frame, the
  Arabic links) need the Mac test bed or an emulator.
