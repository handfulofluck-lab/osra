### iOS child agent — OSRA Kids speaks Arabic on every screen (5.5, Arabic Language Bureau)
- The pairing, Status, parent-PIN and app-group screens read their text through a new `L10n` from the package's
  `Localizable.strings` (en, ar) and `Localizable.stringsdict` (the "tries left" and "try again in N s" plurals),
  instead of English literals in Swift. The Arabic is the Bureau's 76 lines, approved by Karim on 12 Nov (11:20Z),
  copied exactly.
- Changed lines: the two Arabic location prompts and `block_window_line` («محجوب بواسطة»); the pairing section is
  titled "OSRA Kids", and a failed identity save shows a plain sentence while the technical cause goes to the log;
  the group summary is the parent app's three-count line, zeros included.
- English text is otherwise unchanged, so the shared parent-PIN vectors still hold. New `L10nTests` (key parity,
  every key the code reads, the Arabic plural and formatted lines).
