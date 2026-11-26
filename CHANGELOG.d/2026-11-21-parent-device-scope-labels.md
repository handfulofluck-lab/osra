### Parent app — the device and internet controls now name what they reach (#969)
- A parent tapped **Resume** expecting apps to work again and nothing happened, because the card showed **Resume**
  (this handset) and **Resume net** (every device the child has) side by side with nothing saying which was which.
- The Overview card now uses the scoped labels that already exist in both catalogs: **Pause device** / **Resume
  device** for the handset, **Pause internet** / **Resume internet** for the child-wide control.
- **No new copy and no ARB change:** `commandPauseDevice`, `commandResumeDevice`, `commandPauseInternet` and
  `commandResumeInternet` are already in `app_en.arb` and `app_ar.arb` with approved Arabic, so this is a swap of
  which keys the card reads, not a wording change.
- A widget row asserts the four scoped labels are on the card and that `Pause net` / `Resume net` are gone, so the
  ambiguous pair cannot come back.
