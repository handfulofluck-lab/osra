### Parent app — a blocked app rule says it is hidden on the iPhone (ADR-0037 decision 3)
- When the child has an iPhone, each blocked app rule in the rules editor reads "On the iPhone, this app is
  hidden instead of showing the OSRA screen.": iOS hides a blocked app id rather than shielding it, unlike an
  app group. Nothing changes for a child with only Android phones.
- One new string in both ARBs; the Arabic is a draft pending Karim's review.
- New `rules_hidden_on_iphone_test.dart` (2 rows).
