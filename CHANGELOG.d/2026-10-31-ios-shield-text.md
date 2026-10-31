### iOS agent — the block screen names the window and its end time, in English and Arabic (#511)
- The shield was fixed English text ("Blocked by OSRA" and a generic subtitle). It now says which window holds
  the app and when it ends ("Blocked by Bedtime until 07:00", «محجوب بسبب وقت النوم حتى 07:00», or the routine's
  name), with the title and buttons in Karim's approved wording, in the phone's language. An app the parent
  blocked outright, an allowed or essential app, a website and a time outside every window get no line, as on
  Android (#496).
- `ShieldText` (pure) decides from the rules the last sync stored in the app group; the strings ship in the
  package's `Localizable.strings` (en, ar). The label and the time are wrapped in FSI/PDI (#506).
- Rows: `ShieldTextTests`, including the Arabic pinned verbatim.
