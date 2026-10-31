### Parent app + API — the Edit rules screen opens whatever daily limit is stored (#505)
- The screen-time sliders run from 15 to 600 minutes, but a value stored by another client could sit
  outside that, and `Slider` threw: the whole editor failed for that child (Flip4, 1440 stored).
- **App.** The slider's thumb is clamped to its range (`limitSliderPosition`). The title still shows the
  stored value, and the draft keeps it until the parent moves the slider, so saving another rule never
  rewrites the limit. 0 (no limit) is handled the same way.
- **API.** `dailyLimitMinutes` and `weekendLimitMinutes` are capped at 1440, the minutes in a day (was
  10080). The 600 cap stays in the app's slider only.
- Rows: three widget rows (1440, 0 and 5 stored open without an exception, show their value, and save it
  unchanged), a unit row for the clamp, and an API row (1441 refused, 1440 accepted).
