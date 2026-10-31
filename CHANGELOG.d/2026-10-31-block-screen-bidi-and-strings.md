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
- **Arabic in all five**, Karim's Q12 approved 31 Oct 16:28Z and copied word for word: «حجب والدك أو والدتك هذا التطبيق»,
  «انتهى وقت الشاشة اليومي», «اطلب السماح», «أُرسل الطلب إلى والدك أو والدتك» and «الخروج إلى الشاشة الرئيسية», so an Arabic
  phone reads the whole screen rather than only its reason line. Each is pinned as a literal (the #487/#502
  shape), which is the only cover that exists: nothing else reads `values-ar`.
- Rows: `BlockWindowCopyTest` (9) — the three #506 rows pin the isolates as codepoints, assert the stripped
  sentence is unchanged (they are zero-width), and cover an Arabic routine name the same way; the English rows
  keep their meaning with the isolates allowed. `ChildSystemStringsTest` gains two: the five Arabic lines
  pinned verbatim with their English sources, and a source-text row that `BlockActivity` holds none of the five literals while
  reading each resource — which is the fault that produced the half-English screen.
- Mutants: dropping the isolation reddens the three #506 rows and nothing else; hardcoding one sentence back
  into `BlockActivity` reddens the source-text row; one Arabic word changed reddens the Q12 pin and nothing else.
- **Not done, deliberately:** the phone row stays Claude's. R1 re-runs on the Flip4 after this merges — a JVM row
  proves the emitted string, not how it renders with a Latin name inside an RTL sentence.
