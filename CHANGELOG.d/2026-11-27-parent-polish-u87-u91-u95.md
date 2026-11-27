### Parent app — four small copy and layout fixes from the Saturday polish list (#650)

- **U87:** the setup grant row says "Web filter" instead of "Web filter (VPN consent)". The parenthetical described our mechanism, not the parent's choice. Both Arabic labels use the Arabic Language Bureau's approved term, «تصفية المواقع» — the grant row and the Rules tab now read the same, which closes the #604 split on that term.
- **U89:** the privacy screen's "Kept, then deleted automatically" header renders in sentence case. The catalog value was already sentence case in both locales; the widget upper-cased it, so the fix is in the widget and no string changed.
- **U91:** the social preview on an alert now has its own failure sentence ("Couldn't load the preview. Check your connection and try again.") instead of borrowing the alerts-list one, which told the parent the wrong screen had failed. The Arabic is the Arabic Language Bureau's line, verbatim.
- **U95:** the rules editor's scrollable tab strip is start-aligned, so the first tab no longer shifts sideways when the labels start to overflow at large text.

Each has a test in `test/u_items_parent_test.dart`, `test/alert_detail_p15_test.dart` or `test/privacy_screen_test.dart`, with the mutant that breaks it stated beside it. UI/UX and Arabic review and the code receipt are on PR #1260.
