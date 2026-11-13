### A quiet iPhone is no longer reported as removed (#681, #634 D5)
- **Before:** one silence window — 30 minutes — for every phone. That is right on Android, where the agent
  reports on a cadence we control and a 30-minute quiet is the `pm clear` bypass the watch exists to catch.
  It is wrong on an iPhone, which the OS suspends between wakes: a healthy phone in a school bag for an hour
  raised a **critical** "your child's phone went silent" alert, and repeated it every gap.
- **After:** the window is per platform. Android and every unstated platform keep `DEVICE_SILENT_MINUTES`
  (30 by default, clamped to two telemetry intervals); iOS and macOS use `DEVICE_SILENT_MINUTES_APPLE`,
  360 minutes by default, clamped up to 120 because a false "the phone may have been removed" is worse than a
  late true one. The candidate query uses the shortest window in play and each device is then judged by its
  own, so Android still alerts at 45 minutes.
- **The alert body now names the elapsed time, not the window.** It said "has not reported for 360 minutes"
  about a phone unseen for seven hours — true of the threshold and false of the phone. The window travels in
  the metadata instead, where the test and the audit read it.
- Rows: Android keeps its 30-minute window; an iPhone at five hours raises nothing and at seven raises one;
  a too-small Apple value is raised to the floor; an Android phone at 45 minutes still alerts, which is the
  regression this change had to avoid.
- **Not done, deliberately:** the wording #681 asks for ("may be off, or the app may have been removed") is
  the UI/UX Bureau's line (#650), and a separate alert category is a `shared-types` and parent-app change. The
  mechanism ships behind the existing `device_silent` category with its existing severity so an iPhone that
  dies is no longer silent, and the sentence lands when the Bureau signs it.
