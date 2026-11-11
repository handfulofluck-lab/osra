### Child agent — the PIN gate runs full-screen in a task of its own (1.1)
- The gate the accessibility guard opens is now `TamperGuardTaskActivity`: the same screen, declared as the
  root of its own non-resizeable task (`taskAffinity=""`). Before, it opened inside OSRA's task, so a
  correct PIN finished into OSRA's status screen; now it returns to the screen the parent opened (#533 claim 3).
- The guard's gate goes Home if it finds itself sharing the screen anyway, and the guard judges protection
  screens again while any gate shares it, or when a window other than the one it guarded opens. In-app gates
  (`TamperGuardActivity`: re-pair, remove protection, ring) never refuse, so their callers keep the result.
- New rows in `GuardDebouncePolicyTest` and `TamperGuardLandsHomeWiringTest`.
