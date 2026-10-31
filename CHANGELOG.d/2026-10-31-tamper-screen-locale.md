### Child agent — protection screens are recognised by what they are, in any system language
- `TamperScreenPolicy.classify` now takes the window's class (from the last `TYPE_WINDOW_STATE_CHANGED`
  event, kept by `AccessibilityMonitorService` while the same package is in front). The device-admin
  sheet (`DeviceAdminAdd`), the package installer's `UninstallerActivity` and App info
  (`InstalledAppDetails`, `InstalledAppDetailsTop`, `AppInfoDashboardActivity`) classify by class,
  whatever words they show. The screen still has to name the agent.
- The word lists, now a fallback for screens whose class is not known, carry Arabic next to English.
  Text is folded first (Arabic short vowels, shadda and tatweel dropped; hamza forms of alef and waw made
  bare), so one list matches the variants OEMs render. English matching is unchanged.
- Rows in `TamperScreenPolicyTest`: each class without a verb (Arabic text, or only the agent's name);
  a class that does not name the agent stays `NONE`; the Arabic lists classify the four screens; an
  unrelated Arabic Settings screen stays `NONE`; the text folding. The English rows are unchanged.
