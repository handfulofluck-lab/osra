### OSRA Kids for iPhone — stable accessibility identifiers on every screen (#669 part 2)
- **Before:** the test bed's XCUITest driver tapped controls by their label, so a script written in English broke
  on an Arabic phone.
- **After:** every control on the pairing, status, parent-PIN and app-group screens carries an identifier from
  `A11yID` (for example `pair.code`, `status.syncNow`, `pin.continue`, `groups.<id>.blocked`), and so do the
  status and error lines a script reads. Nothing a person sees changed. The block screen is drawn by iOS from
  `ShieldConfiguration` and takes no identifiers.
- Rows (`A11yIDTests`): identifiers are unique ASCII; a scan of the three view files fails at the file and line of
  any `Button`, `TextField`, `SecureField`, `NavigationLink`, `Toggle`, `Menu` or `Picker` without one, in the
  `Button(…)` and `Button { } label:` shapes alike (20 on `main`, 0 now; fixture rows prove each shape is seen); and
  every fixed identifier is used on a screen.
