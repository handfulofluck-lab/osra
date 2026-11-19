### API — `recordConsent`'s comment now matches what it does (#886 follow-up)
- Documentation only: the docstring said the function appends "through a transaction client" and it takes
  none. It now says what is true — an app tick is one append on the module client — and points at
  `recordSignupConsent` for the case that does need a transaction. No behaviour, schema or wording changed.
