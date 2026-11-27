### Parent app — three small copy and layout fixes from the Saturday polish list (#650)

- **U87:** the setup grant row says "Web filter" instead of "Web filter (VPN consent)" in English. The parenthetical described our mechanism, not the parent's choice. The Arabic line stays as it is until the Arabic Language Bureau posts its replacement.
- **U91:** the social preview on an alert now has its own failure sentence ("Couldn't load the preview. Check your connection and try again.") instead of borrowing the alerts-list one, which told the parent the wrong screen had failed. Arabic is the Arabic Language Bureau's line, verbatim.
- **U95:** the rules editor's scrollable tab strip is start-aligned, so the first tab no longer shifts sideways when the labels start to overflow at large text.

Verified by tests in `test/u_items_parent_test.dart` and `test/alert_detail_p15_test.dart`, each with the mutant that breaks it stated beside it. UI/UX and Arabic review and the code receipt are on PR #1260.
