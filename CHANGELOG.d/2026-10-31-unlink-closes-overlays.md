### Child agent — an unlink closes a block or lock screen left open (#488)
- A block screen that was open when the family was deleted kept saying "This app is blocked by your parent"
  after the release. The block screen now listens for the unlink while it is started and closes, and on
  return from the background it closes if the phone is no longer paired (the #479 two-path shape).
- The lock/pause overlay listens for the unlink too and closes once the stored lock is cleared. Its
  background path already closed on return, because the unlink clears the lock before it announces itself.
- `UnlinkedOverlayWiringTest` pins the receivers, the block screen's return path and the lock screen's
  reliance on the unlink clearing the lock.
