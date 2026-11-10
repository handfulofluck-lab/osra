### Child agent — the PIN gate runs full-screen in a task of its own (1.1)
- The gate the accessibility guard opens is now `TamperGuardTaskActivity`: the same screen, declared as the
  root of its own non-resizeable task (`taskAffinity=""`). Before, it opened inside OSRA's task, so a
  correct PIN finished into OSRA's status screen; now it returns to the screen the parent opened (#533 claim 3).
- A gate in multi-window mode relaunches full-screen (or goes Home if that does not hold), and the guard
  judges protection screens again while that is so, or when a window other than the one it guarded opens.
  In-app callers that wait for the gate's result keep `TamperGuardActivity`.
- New rows in `GuardDebouncePolicyTest` and `TamperGuardLandsHomeWiringTest`.
