### Child agent — a blocked app plays no audio, however it is started (#444 C4)
- Karim's Flip4 run (29 Oct 15:08Z): with YouTube blocked and the block screen up, Play on YouTube's media
  notification in the shade resumed the audio behind the block screen.
- The agent now takes audio focus when the block screen goes up, which pauses a well-behaved player. When
  media playback starts within 2 s of a media notification from a **blocked** app (the shade, a headset
  button, the lock screen), it takes focus again and sends one pause key. It gives focus back as soon as an
  allowed app posts a media notification, and it never pauses an allowed app.
- From another app's media notification the agent reads only its category and template, never the title,
  artist or artwork. No NotificationListener is needed, so this works in the Play build.
- `MediaBlockPolicy` is pure; `MediaBlockPolicyTest` covers the raise, the blocked resume, the allowed app,
  a stale or missing post, and the last poster winning.
