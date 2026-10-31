### Child agent — the block screen's whole sentence survives Arabic, and speaks the phone's language (#506)
- **What a child sees on an Arabic phone.** Before: bedtime and school hours read correctly, but a routine the
  family named in English came out as «محجوب بسبب Homework 23:50 حتى» — the name and the time swapped under the
  Unicode bidi algorithm, so the sentence named the time as the window. After: «محجوب بسبب Homework حتى 23:50»,
  in the order the template declares, whatever the name is written in.
- **How:** `BlockWindowCopy.line` wraps **both** the label and the end time in FSI…PDI (U+2068 / U+2069), so each
  is a self-contained run whose direction comes from its own first strong character. FSI rather than LRI/RLI
  because the direction is the family's text, not ours; and hand-rolled rather than
  `android.text.BidiFormatter` so the object stays pure and the JVM rows can pin the exact emitted string.
- **The rest of the screen moves to resources** — `block_title_blocked`, `block_title_time_limit`,
  `block_request_access`, `block_request_sent`, `block_exit_home` — because only the reason line was localised;
  the title and both buttons were English literals in the composable.
- **Arabic in three of the five**: Karim's Q12 approval covers the title, "Request access" and "Exit to Home
  screen" — the same three the iPhone shield carries (its `ar.lproj` cites the approval, merged with #512), so
  an Arabic phone now reads the whole screen except the daily-limit title and "request sent". Those two were not
  in Q12, so they stay English and a row holds exactly that split: an Arabic value for either turns the suite red
  until his word arrives.
- Rows: `BlockWindowCopyTest` (9) — the three #506 rows pin the isolates as codepoints, assert the stripped
  sentence is unchanged (they are zero-width), and cover an Arabic routine name the same way; the English rows
  keep their meaning with the isolates allowed. `ChildSystemStringsTest` gains two: the five keys' English
  wording with "no Arabic yet", and a source-text row that `BlockActivity` holds none of the five literals while
  reading each resource — which is the fault that produced the half-English screen.
- Mutants: dropping the isolation reddens the three #506 rows and nothing else; hardcoding one sentence back
  into `BlockActivity` reddens the source-text row; adding an Arabic value reddens the Q12 row.
- **Not done, deliberately:** no `values-ar` entries and no change to the phone row's ownership — Claude re-runs
  R1 on the Flip4 after this merges, and Karim's Q12 wording lands as a one-commit follow-up when he answers.
