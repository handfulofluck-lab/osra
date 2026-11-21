### Parent app — searching finds a preinstalled app without touching the filter (#953)
- The app picker hides **preinstalled** apps behind a "Show system apps" chip, and the search ran through the same
  filter. So a parent who typed the name of a preinstalled app — YouTube on essentially every Android image — got the
  no-match line, with no hint that a switch they were never told about was hiding it.
- Search now covers the whole reported list; the chip still filters **browsing**, so a phone with two hundred
  preinstalled apps is still usable.
- The chip's label and the rest of #953 (the iPhone-centric guidance, the mixed-device headings) are unchanged here:
  they need new copy from the Language Bureaus, requested on #604.
- Verified: CI only — there is no Flutter toolchain on this PC, so the new widget row has never run locally.
