### Child agent — the pairing screen speaks Arabic (plan 2.7, #433 review b)
- The Android agent's pairing screen and the parent-PIN step after it now read their copy from resources:
  35 strings, from the server and code fields to the "waiting for your parent" line, the declined and
  expired messages, the PIN step, and the scanner and network-error lines. The Arabic is Karim's approved wording (#439, 2026-10-29), with
  "your parent" as «والدك أو والدتك», as in the reset-code notice.
- `PairingStringsTest` pins every Arabic line as a literal, checks that both files carry the same keys
  and that the format arguments survive. The Arabic rendering on a device is for the next phone run.
- An unreadable or foreign QR code now shows one fixed line in both languages; the technical reason is
  logged instead of shown. The last three lines are Karim's approval of 2026-10-29 11:43Z.
- The test task now declares `src/main/res` as an input, so a local build reruns the string tests after a
  translation edit instead of reporting them UP-TO-DATE.
- Still English on this form: the title and the two field hints, waiting for Karim's wording.
