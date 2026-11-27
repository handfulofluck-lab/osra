### Parent app — an iPhone child's web-filter card says what the phone really does (#1279, #1280)

When an iPhone reports its web-filter state, ready or degraded, the browsers card no longer says "Not yet available on iPhone". It shows one new sentence with the primary globe:

> On iPhone, the sites you block are blocked in Safari and other browsers. Categories and SafeSearch aren't available on iPhone yet.

- Blocked sites apply through WebContentSettings, which covers WebKit browsers, so the sentence promises no more than that (UI/UX Bureau, #1280 7224921514).
- The Android sentence is not reused: it claims categories and SafeSearch, which an iPhone doesn't have (lead review 7224916449).
- An iPhone that reports `unavailable` — Screen Time access is absent (`CapabilityReport.swift:74-75`) — gets the warning "Not blocking yet" pill instead of the sentence, because nothing is blocked in that state (Codex, 7227751401).
- "Not yet available on iPhone" stays only for a phone that has reported nothing.
- The Android card keeps #1264's warning globe until the phone reports ready; this branch folds that merge and does not recolour it.

New string `p12IphoneBlockedSitesOnly`: EN from the UI/UX Bureau, AR from the Arabic Bureau (7224950500). The tr/id/ms/fr/ur drafts are in the Language Bureaus' catalogues (7224965941) behind the ADR-0042 switch.
