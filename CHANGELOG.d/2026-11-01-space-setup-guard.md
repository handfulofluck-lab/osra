### Child agent — the parent PIN also guards the screens that create a second space
- **What changes:** on a Samsung phone, opening **Dual Messenger**'s app list or **Secure Folder**'s setup now
  brings up the parent-PIN gate, like the device-admin, uninstall and App-info screens. The parent gets the
  usual "protection screen opened" alert. A verified PIN gives the usual two minutes to finish.
- **How the screen is recognised:** by its package **and** window class, both taken from a Flip4 capture
  (One UI, SDK 36):
  - `com.samsung.android.da.daagent` / `DualAppActivity`
  - `com.samsung.knox.securefolder` / `WelcomeActivity`

  These screens never name OSRA, so this is the one place where the class decides alone. The package keeps it
  to the one system app that hosts each screen. A same-named class elsewhere, or another screen of the same
  app, is not guarded.
- **Not covered:** other OEMs' clone or "second space" features, and Secure Folder screens after setup. Each
  needs its own capture before it is added.
