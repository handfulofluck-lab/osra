### Parent app — the command-history and consent error cards say "try again" once (#841 follow-up)
- The UI/UX Bureau's follow-up on #841: after the messages became whole sentences ("… Check your connection
  and try again."), the command-history and consent error cards still printed a small "Try again" line above a
  Retry button — the same instruction twice, one of them not doing anything.
- The line is gone in both cards; the button stays. Nothing else about the layout changed.
- No string was removed from the ARBs: `tryAgain` is still used wherever a plain button label is the whole
  affordance, and the sentences keep their own "try again" clause.
- Verified: `flutter analyze` on both files is clean and the command-history, consent and error-text suites pass;
  the whole parent-app number is on the PR.
