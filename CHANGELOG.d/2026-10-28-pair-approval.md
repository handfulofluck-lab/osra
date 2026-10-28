### Pairing — the parent approves each new device (plan 2.7, #433)
- A pairing code alone no longer pairs a device. The phone's claim waits; the parent's pairing screen,
  already open on the code, shows the phone that is asking ("… wants to be paired") with **Allow** and
  **Deny**, and only after Allow does the phone get its device token, exactly once. Deny burns the code,
  and the card offers a new one at once.
- API: `POST /v1/devices/pair/claim` now answers `202 { claimId, pollSecret, expiresAt }`. New routes:
  `GET /v1/devices/pair/:code/claim`, `POST /v1/devices/pair/claims/:id/approve` and `/deny` (parent with
  `devices`, same family), and `POST /v1/devices/pair/claims/:id/poll` (the poll secret is the credential;
  201 with the old claim body after Allow). The device row is created by that poll, never earlier, and
  consent is checked again there. The phone's model, name and OS version are cleaned of control and bidi
  characters and capped at 64 characters. Ten wrong poll secrets burn a claim. Every Allow and Deny is
  recorded (`PairingDecision`, migration `0026`), erased with the child and included in the family export.
- Clients: the parent app, the Android agent, the desktop agent and the iOS agent all claim and then wait
  for the parent's decision. Release Android builds accept a QR code only for `https` on `osratech.com`.
- Measured on a local stack, fresh database: API 666/666, probe 205/0 (0 x 429), e2e 72/0. Each server
  guard was removed in turn and its test or probe row went red. The Flutter, Kotlin, C# and Swift changes
  are compiled and tested by CI only.
- The new Arabic strings await Karim's review.
