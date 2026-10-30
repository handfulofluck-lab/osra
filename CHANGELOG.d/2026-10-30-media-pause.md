### Child agent — a blocked app plays no audio, however it is started (#444 C4)
- Karim's Flip4 run (29 Oct): with YouTube blocked and the block screen up, Play on YouTube's media
  notification in the shade resumed the audio behind the block screen.
- A media notification's accessibility parcel carries the app's media-session token. The agent keeps the
  token of **every** app that posts one (only the token, never the title, artist or artwork). Whenever an
  app's session plays while that app is blocked, the agent pauses that session. It checks on each post, when
  any media player starts, when the session itself reports playing, when the block screen goes up, and after
  each rule sync. So an app that was already playing when the parent blocked it is caught as well. On the
  Flip4 a resume from the shade or the lock screen posts nothing new, so the session callback and the
  playback callback are what catch it.
- No audio focus and no global pause key: an allowed player is never touched, because nothing is paused
  unless its app is blocked at that moment. A token goes when its session ends. No NotificationListener is
  needed, so this works in the Play build.
- `MediaBlockPolicy` is pure; `MediaBlockPolicyTest` has 11 rows, including a resume with no new post (and one that leaves the player count unchanged, R7), a block
  applied while playing (R5, R6), an allowed player untouched, unblock and re-block, a destroyed session, and
  not playing means no pause.
