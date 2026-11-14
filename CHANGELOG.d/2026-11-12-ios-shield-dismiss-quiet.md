### iOS child agent — "Exit to Home screen" on the shield no longer alerts the parent (#602 item 1)
- Every tap on the shield's "Exit to Home screen" used to send an `app_blocked` alert ("Shield dismissed by
  child"). Leaving a blocked app is the block working, so it now closes the app and adds one to a local count
  (`shield.dismissals` in the app group) instead. "Request access" still alerts the parent.
- New `ShieldTapPolicy` and `ShieldTapPolicyTests` (5 rows).
