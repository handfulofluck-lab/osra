### API — a harmful message is no longer lost to an English-only fallback (#863)
- The social scan's local keyword fallback read English only and held **no substance terms**, and it ran
  only when the AI engine was unreachable (`ai.verdict ?? localKeywordCheck(text)`). A child writing in
  Arabic, or sending drug words in English, therefore scored safe on both the rules layer and the
  fallback — the 19 Nov staging run sent both and the parent saw nothing.
- The fallback now carries high-precision Arabic terms for cyberbullying, self-harm, grooming and
  substance use, plus English substance words, and **every Arabic stem is token-bounded** so `فيب`
  ("vape") no longer matches `فيبدأ` ("so it starts"), `خمر` no longer matches `خمري` (maroon) and `غبي`
  no longer matches `رغبي` (rugby). Alerting wrongly is its own harm, and the negative rows pin it.
- `scanOne` now takes the **union** of the model and the local check: a local hit survives a model "no",
  and when both flag the concern types are merged and the higher severity stands, so a mixed message
  cannot lose a critical self-harm clause to a warning-severity bullying one.
- Live handset proof is still open: the Flip4 pass that shows an alert on the parent is the device half
  of #863.

Refs: #863
