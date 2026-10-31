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
  the title and both buttons were English literals in the composable. Arabic for these five is **Q12, proposed
  to Karim and not yet approved**, so `values-ar` has no entry and a row holds that: an Arabic value appearing
  there before approval turns the suite red.
- Rows: `BlockWindowCopyTest` (9) — the three #506 rows pin the isolates as codepoints, assert the stripped
  sentence is unchanged (they are zero-width), and cover an Arabic routine name the same way; the English rows
  keep their meaning with the isolates allowed. `ChildSystemStringsTest` gains two: the five keys' English
  wording with "no Arabic yet", and a source-text row that `BlockActivity` holds none of the five literals while
  reading each resource — which is the fault that produced the half-English screen.
- Mutants: dropping the isolation reddens the three #506 rows and nothing else; hardcoding one sentence back
  into `BlockActivity` reddens the source-text row; adding an Arabic value reddens the Q12 row.
- **Not done, deliberately:** no `values-ar` entries and no change to the phone row's ownership — Claude re-runs
  R1 on the Flip4 after this merges, and Karim's Q12 wording lands as a one-commit follow-up when he answers.
