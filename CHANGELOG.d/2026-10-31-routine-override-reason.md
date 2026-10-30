### Parent app — an app row says which window is holding it shut (#456)
- On the child's **Apps** tab, a row whose app is currently blocked by a window now says so:
  "Blocked now by Homework (until 19:00)", or "School hours", or "Bedtime". The sentence is drawn from
  the same ordering the child agent applies (`RuleEngine.evaluate`), so it cannot promise an app is open
  when the phone would refuse it, or vice versa.
- **The ordering matters and is the whole design.** A routine is read *before* per-app rules, so a
  routine can override an app the parent set to *allowed* — that is the sentence this change exists for.
  Bedtime and school hours are read *after* per-app rules, so an app set to *allowed* is never described
  as blocked by them: `RuleEngine.kt:66` returns ALLOW first. An app with `block` or `time_limit` gets no
  window sentence either — its own rule is the reason, and "blocked by school hours" would be a lie.
- New pure resolver `lib/features/rules/active_window.dart` (`activeWindowFor`), with the agent's exact
  window semantics: `[start, end)` and the overnight wrap, equal times are empty, school hours restricted
  to their days. The clock is a provider (`clockProvider`) so a row can pin a weekday morning.
- One new string pair (en/ar): `blockedNowBy` — "محجوب الآن بسبب {reason} (حتى {time})".
- A row whose app the parent **blocked** gets no sentence even inside a routine (#474 review): the app
  stays blocked after the routine ends, so "Blocked now by Homework (until 19:00)" would promise it
  opens. `time_limit` keeps the sentence — there the app does open again.
- `test/routine_override_test.dart`: 16 unit rows over the ordering and window arithmetic, 3 widget rows
  on the real screen (routine override named; nothing claimed after the window ends; an allowed app not
  described as school-hours-blocked). Mutant: remove the `action == 'allow'` short-circuit and the third
  widget row goes red with a false "School hours" sentence.
- **Not in this change, and filed as its own issue:** the child's own block screen still says only
  "blocked" — naming the window there needs the agent's engine to report *why*, which is an architecture
  call rather than a copy of this resolver.
- Known limit, stated rather than hidden: the sentence is computed from the **parent's** clock. A parent
  in a different timezone than the child reads the window shifted; feeding `family.timezone` into
  `clockProvider` is the next step.
