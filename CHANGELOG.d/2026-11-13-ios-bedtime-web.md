### OSRA Kids for iPhone — bedtime also shields websites (osra-security#19)
- During bedtime, and during a routine that lists only the allowed apps, the shield now covers **every website**
  as well as every app except the allowed ones (`store.shield.webDomainCategories = .all()`). The allowed apps stay
  usable; web pages are shielded until the window ends, when the window's own store is cleared as before.
- `ShieldPolicy.shieldsAllWeb` makes the decision testable. Rows (`RuleSyncTests`): it is true for "everything
  except", false for "only these apps" and for no shield, and a source row keeps the monitor applying it in the
  "everything except" branch.
