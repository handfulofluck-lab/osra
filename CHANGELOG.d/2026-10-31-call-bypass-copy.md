### Parent app — a call-bypass alert says the call kept going (#444 follow-up)
- The `block_bypass` alert dialog now carries the sentence Claude ruled on, **only when
  `metadata.layout` is `call`**: *"The call app was blocked, but its call kept going under the block
  screen. OSRA can't end another app's call, so the screen stays blocked until the call ends."*
- **Why the dialog and not the list or the FAQ:** it is the screen the parent opens from that exact
  alert. An explanation they may never open is not an explanation at the moment they need it.
- **Why only `layout: call`:** a split-screen or PiP bypass is explained by the alert body already;
  adding "the call kept going" there would be a sentence about something that did not happen. A row
  asserts the negative.
- New string pair (en + ar): `alertCallBypassNote`. **The Arabic is a draft and needs Karim** — it is
  in the ARB so parity holds, and it is the one line in this PR he has to approve, the same path as
  #480 and the #477 strings.
- Rows: `test/alert_call_bypass_note_test.dart` — a `call` alert shows the note; a `split_screen`
  alert shows nothing. Mutant: drop the `layout == 'call'` condition and the second row goes red.
- **Not in it:** any change to what the agent does. #482 is the behaviour; this is the sentence.
