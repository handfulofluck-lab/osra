### Android child agent — protection screens are covered in split screen and pop-up windows (osra-security#7)
- While a protection screen (device admin, uninstall, app info, Private DNS, space setup) shares the screen with
  another window, the accessibility service draws an opaque `TYPE_ACCESSIBILITY_OVERLAY` cover over that
  window's bounds. The cover takes touches, never focus, and comes off when the screen closes or a parent PIN
  starts the grace window. The PIN gate opens and the parent is told once, when the cover goes up.
- Every visible application window is judged, not only the active one, and window changes
  (`typeWindowsChanged`) now reach the guard.
- New `GuardCoverPolicy` with `GuardCoverPolicyTest` (9 rows) and `GuardCoverWiringTest` (4 rows). The wiring
  rows fail on main's sources.
