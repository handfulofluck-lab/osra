### Parent app — the generated l10n matches its ARB, and CI says so (#841 follow-up)
- The committed `app_localizations*.dart` had drifted from the ARB they are generated from: on `main`, one
  `flutter pub get` rewrote `app_localizations.dart` and `app_localizations_ar.dart` — output ordering, a
  doc comment for `consentRequired`, an escaped apostrophe in one English doc, and in Arabic the line
  wrapping of `familyNameHelper`. No user-visible string changed: the Arabic is byte for byte the same, only
  laid out differently. Found on #841 and routed here by the coordinator (#50, 19:25:39Z).
- This PR regenerates both with the Flutter version CI pins (3.47.9, the same one in `parent-app.yml`) so the
  committed files are what the toolchain produces. **No ARB text is changed** — the Arabic Language Bureau
  rules the ARB is the source of truth, and this PR makes the generated files follow it.
- `parent-app.yml` gains one step after `flutter pub get`: if `git diff --exit-code -- lib/l10n` finds the
  generator changed anything, the job fails with a message saying to run `flutter gen-l10n` and commit the
  result. `pubspec.yaml` sets `generate: true`, so `pub get` has already written what `gen-l10n` would write,
  which is what makes the diff a stale-file check rather than a second generation.
- Why a row and not a review habit: #862 was an escaped apostrophe hand-edited into a generated file, and
  #841 found the Arabic generated file behind its ARB. Both were caught by a human reading a diff; neither
  could be caught by a test, because the generated file compiles and the suite is green either way.
- Verified on this host (Flutter 3.47.9 / Dart 3.13.7): regeneration produces the two files above and
  nothing else in `lib/l10n`; `flutter analyze` and `flutter test` in `apps/parent-app`, plus
  `node scripts/check-workflows.mjs --strict` and `node scripts/check-ci-paths.mjs` — the numbers are on the
  PR. The new step was tried both ways: with the tree clean `git diff --exit-code -- lib/l10n` exits 0; with
  one generated line reverted and `flutter pub get` re-run, it exits 1.
