### Parent app — an iPhone child's web-filter card shows the phone's real state (#1279)

When an iPhone reports its web-filter state, the card no longer says "Not yet available on iPhone":
- `web_filter: ready` shows the same enforcement sentence the Android card uses — blocked sites apply through WebContentSettings on the phone.
- any other reported state (`degraded`, still setting up) shows the warn "Not blocking yet" pill the rest of the screen uses, with the warn-coloured globe.

The roadmap note stays only for a phone that has reported nothing. **No new strings** — the card reuses `searchSafetyEmptyBody` and `p12NotBlockingYet`, so no Bureau copy is created by this change; the Bureaus still review the screen.
