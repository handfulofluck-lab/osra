### Child agent — the pairing screen speaks Arabic (plan 2.7, #433 review b)
- The Android agent's pairing screen and the parent-PIN step after it now read their copy from resources:
  32 strings, from the server and code fields to the "waiting for your parent" line, the declined and
  expired messages, and the PIN step. The Arabic is Karim's approved wording (#439, 2026-10-29), with
  "your parent" as «والدك أو والدتك», as in the reset-code notice.
- `PairingStringsTest` pins every Arabic line as a literal, checks that both files carry the same keys
  and that the format arguments survive. The Arabic rendering on a device is for the next phone run.
- Still English on this screen: the scanner's two error lines for an unreadable or foreign QR code, which
  were not in the reviewed list.
