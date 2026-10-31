### Child agent — the device-admin sheet counts as a protection screen only while our admin is active
- One window class serves the admin sheet for activation and deactivation alike (AOSP `DeviceAdminAdd`, and
  Samsung's `SecDeviceAdminAdd`, recorded on the Flip4). `TamperScreenPolicy.classify` now takes
  `ourAdminActive` (`DevicePolicyManager.isAdminActive` for our component): the sheet is a deactivation only
  then, and the activation the parent runs in setup is never guarded, by class or by words.
- `SecDeviceAdminAdd` joins the admin classes. The admin list (`DeviceAdminSettingsActivity`) is an explicit
  never-guarded class. From the Flip4 in Arabic: «إلغاء التفعيل» / «إلغاء تفعيل» join the deactivate verbs
  (never bare «إلغاء», which is Cancel) and «توقف إجباري», the force-stop dialog title, joins «إيقاف إجباري».
- Rows in `TamperScreenPolicyTest` use the captured classes and strings: the Samsung sheet active (by class and
  by verb) and inactive, the AOSP sheet inactive, the Arabic admin list, the Arabic force-stop dialog.
