### Parent app — Lock and Pause internet light up for an iPhone child once its phone can do them (#1089)
- The home card used to grey out all four buttons for any iPhone-only child. Lock and Pause internet now
  go live as soon as that iPhone's own report says `lock_screen` / `pause_internet` are `ready` (the
  Screen Time shield build, #1275). Until then they keep saying "Not yet available on iPhone".
- Lock and its Undo now reach the iPhone too, instead of Android devices only. Bonus time is unchanged, so
  the "Not yet available on iPhone" banner stays as the visible reason for its faded buttons (U104).
