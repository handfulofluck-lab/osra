### Child agent — the block screen names the window that is holding the app (#473)
- **What a child sees now.** Where the rules hold an app shut by a **routine, bedtime or school hours**,
  the block screen adds one line: *"Blocked by School hours until 15:00"*, *"Blocked by Bedtime until
  07:00"*, or the family's own routine name — *"Blocked by Homework until 19:00"*. Before this, a child in
  a Study routine and a child kept out of school hours read the same sentence.
- **Only windows are named.** A pause, an explicit `block`, a `time_limit` and the blocklist produce **no**
  line: naming a window there would promise the app opens when the window ends, and it does not. That is
  the same ordering point #456/#474 settled for the parent app, from the phone's side.
- **One implementation, not two.** The two window steps moved out of `RuleEngine.evaluate` into
  `routineWindow` and `screenTimeWindow`, which `evaluate` now calls in exactly the places it returned
  BLOCK; `RuleEngine.windowFor` answers the same question with the reason, taking the same short-circuits
  in the same order. The existing suite is the proof the refactor changed nothing (both flavours green).
- **The wire is three extras** (`window_kind`, `window_name`, `window_ends`). They exist only when a window
  fired, and the screen treats an unknown kind or a missing end as "no window" rather than half a sentence;
  an intent from an older build renders today's screen byte for byte.
- The window belongs to the **request** (`BlockRequest.window`), not to the screen's local state, because
  `BlockActivity` is `singleTask` — a stale window from the previous app would be the #217 bug again.
- Rows: `RuleEngineWindowReasonTest` (10), `BlockWindowCopyTest` (5, incl. a blank routine name and the null
  case) and `BlockWindowWiringTest` (3, the three halves of the wire). Mutants run: dropping the app-rule
  short-circuit reddens four engine rows; returning a line for a null window reddens `no window means no
  sentence`; changing the ends extra reddens the launcher row. Two earlier attempts did not compile and
  were discarded rather than counted.
- **The screen's copy is still English-only** — `BlockScreen`'s strings are hardcoded and predate this
  change, so the new line follows that rather than inventing a one-string localisation path. Localising the
  whole screen (and this line with it) is its own issue; the Arabic for this sentence goes to Karim as Q10
  when that lands.
