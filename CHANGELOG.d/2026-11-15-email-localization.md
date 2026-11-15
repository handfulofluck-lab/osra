### Email — localized invitations and digest counts (#796)
- Invitations map roles to whole sentences, handle every missing inviter/family-name combination without "A parent" or "the your", and isolate names in HTML and plain text.
- Arabic digest titles use `Intl.PluralRules` and the Bureau's exact rows. Screen time has the six approved forms; sites, blocked counts, concerns, calls and SMS use the approved label/number shape. English singular/plural forms no longer use `concern(s)`.
- No live mail was sent and no real family data was used. Mail-client/RTL picture evidence and independent verification are reported separately before readiness.
