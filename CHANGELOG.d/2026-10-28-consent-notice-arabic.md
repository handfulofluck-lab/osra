### Parent app — the consent notice is in Arabic, and 3.1 closes (#426)
- `consentNotice` now reads Karim's approved wording in both languages — *"Before you add a child, we need to confirm
  that you are their parent or guardian."* / *"قبل إضافة طفل، نحتاج إلى التأكّد من أنك وليّ أمره."* — decided at
  09:02Z on 2026-10-28. This was roadmap 3.1's last untranslated parent-facing string, so **3.1 is done**.
- The law names leave the app: COPPA/GDPR-K belong in the privacy policy, not in a sentence a parent reads while adding
  a child, so the old "(COPPA/GDPR-K)" clause is gone from the notice.
- A new row in `onboarding_test.dart` renders the add-child step in Arabic and asserts the Arabic **literal** — not
  `l10n.consentNotice`, which would pass whatever the ARB says — plus that neither `COPPA` nor `Verifiable` appears
  anywhere on the screen. Mutant run: restoring the English sentence in the generated Arabic strings turns that row
  red and nothing else.
