### Parent app — "Phone setup" on the device card: what the phone can do, and what to fix (#4.5 was the report; this is the screen)
- **ADR-0034 decision 3, PR 3 of 3.** Every device card on a child's Overview now carries a Phone setup block:
  when the phone last reported, the grants it is **missing**, and one chip per feature the phone described.
- **The states are the phone's own verdict**, with one exception: `not_supported` is the *server's* word from
  its static table, so it reads **"Not in this version"** rather than as a fault of the phone.
- **An absent feature key renders nothing.** A build that cannot do a feature omits it instead of claiming it,
  so a blank is honest and "Not available" would not be. A row pins that distinction.
- **"Has not reported yet" is a state, not a failure row.** Every agent older than the report — and every phone
  before its first upload — arrives with `setup: null`, and the block says so in one line.
- **A stale report says its age** rather than disappearing: `stale` is the server's judgement on its own clock
  (one telemetry period plus flex, A4), so a phone that went quiet 20 minutes ago is shown, not hidden.
- **Another space is named, never implied.** `profiles.kinds` maps to the three sentences #530 added
  (`clone`/`work`/`other`), and `others: 0` says nothing at all.
- **31 strings, English and Arabic.** Arabic is a **draft pending Karim's review**, as #530's were; no release
  ships before he answers. ARB parity is exact (822 keys each) and the suite asserts an Arabic render, so the
  block cannot end up English-only on an Arabic phone.
- Rows: `device_setup_model_test.dart` (6) and `phone_setup_section_test.dart` (7). Parent suite **586/586**,
  `flutter analyze` clean.
