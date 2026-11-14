### The Family map no longer crashes on iOS when no Maps key is compiled in (#598)
- **Before:** opening Family map on an iPhone aborted with SIGABRT in `checkServicePreconditions`, because
  `GMSServices.provideAPIKey` was never called on iOS — Android reads `MAPS_API_KEY` from the Gradle manifest,
  iOS had no equivalent. A parent who tapped the map lost the app.
- **After, two halves.** The key now has an iOS path: `MAPS_API_KEY` in `Info.plist`, substituted from
  `Flutter/Debug.xcconfig` / `Release.xcconfig`, which CI writes from a secret (empty in a local build), and
  `AppDelegate` calls `GMSServices.provideAPIKey` only when it is genuinely present — including a check for the
  unresolved `$(MAPS_API_KEY)` literal, so a misconfigured build does not hand the SDK a placeholder. And the
  map screen asks `mapIsAvailable(platform, key:)` first: with no key on iOS it renders a "not available" state
  instead of constructing a `GoogleMap`. **A missing key costs a map, not the whole app.**
- **The copy is an existing approved string**, `phoneSetupStateUnavailable` («غير متاح»), not a new English
  one. The specific sentence #598 asks for — "Map unavailable in this build" — needs the Arabic Language
  Bureau, and shipping English-only here would be the raw-key class of bug the localization rows exist for. It
  lands with the Bureau's line.
- **Rows:** `mapIsAvailable` for iOS with and without a key, Android unaffected; and a widget row that sets the
  platform to iOS and asserts the screen draws the state, constructs no `GoogleMap` and throws nothing. Proved
  by deleting the guard, which reds the widget row.
- **Needs Karim:** an iOS-restricted Maps key from his Google Cloud project, added as the CI secret. Until then
  the guard is what a release build ships, which is the honest behaviour rather than an abort.
