### Child agent — the PIN gate always ends the same way
- **What changes:** when the parent-PIN gate covers a protection screen (device admin, uninstall, App info, Private
  DNS, a second-space setup screen), it now always opens **over** that screen.
  - "Go back", the hardware back button and the fifth wrong PIN always land on **Home**.
  - A correct PIN returns the parent to the screen they opened.
- **Why:** the agent used to send an asynchronous system Back just before opening the gate. On the Flip4 (#484,
  1 Nov) that Back sometimes closed the protection screen, leaving the gate over whatever was behind it, and
  sometimes hit the gate itself, which sent the child Home. That gave three different end states across three runs.
  Nothing ever reached the protected action, but the end state was unpredictable.
- **Tests:** `TamperGuardLandsHomeWiringTest` pins three things:
  - no Back or Home is sent before the gate;
  - every exit without the PIN goes through `goHome()`;
  - `goHome()` starts the launcher.
