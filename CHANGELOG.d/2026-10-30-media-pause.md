### Child agent — a blocked app plays no audio, however it is started (#444 C4)
- Karim's Flip4 run (29 Oct): with YouTube blocked and the block screen up, Play on YouTube's media
  notification in the shade resumed the audio behind the block screen.
- A media notification's accessibility parcel carries the app's media-session token. When a **blocked** app
  posts one, the agent keeps that token, and pauses that app's own session whenever it plays. That is checked
  on the post, when any media player starts, when the session itself reports playing, and when the block
  screen goes up. On the Flip4 a resume from the shade or the lock screen posts nothing new, so the session
  callback and the playback callback are what catch it.
- No audio focus and no global pause key: an allowed player is never touched, because its token is never
  kept. A token is dropped as soon as its app is no longer blocked. From the notification the agent reads only
  its category, template and session token, never the title, artist or artwork. No NotificationListener is
  needed, so this works in the Play build.
- `MediaBlockPolicy` is pure; `MediaBlockPolicyTest` has 8 rows: launch, resume with no new post (twice), an
  allowed player untouched, unblocked tokens dropped, not playing means no pause, the raise, and a post with
  no token.
