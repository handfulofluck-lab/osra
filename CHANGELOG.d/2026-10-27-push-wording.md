### Push — Karim's wording for the parent alert, on both platforms (#418)
- iOS `Runner/{en,ar}.lproj/Localizable.strings`: `PUSH_ALERT_TITLE` / `PUSH_ALERT_BODY` now carry Karim's text, Arabic
  exactly as he wrote it (including the hamza in أسرة) and English with the same meaning. Both values are one line with an
  escaped `\n`, so `plutil -extract … raw` yields a real line break.
- `alertPushBodyGeneric` in both ARBs carries the same sentence, so Android's local notification says what iOS's system
  alert says. The Android title stays the translated category title (`alertTitleFor`), as decided on #395.
- The server is untouched: it still sends only `title-loc-key` / `loc-key`, so no child name and no alert detail reaches
  Apple or Google.
- No test pinned the old text — `background_push_test.dart` asserts the body equals `alertBodyGeneric` from the
  localization, so it follows the new wording rather than needing an edit.
