### Child Android — three setup steps now behave on a MIUI phone (#1287, partly)

From Ahmed's five Redmi/HyperOS findings. This lands the three that need no new wording; the two copy-dependent parts (the restricted-settings sentence and naming MIUI's two pop-up switches) wait for the UI/UX and Arabic Bureaus.

- **Accessibility step opens OSRA's own switch** where the platform supports it: on API 33+ `android.settings.ACCESSIBILITY_DETAILS_SETTINGS` with our service component, falling back to the general list when the OEM skin does not resolve the details activity (MIUI/HyperOS, some OnePlus builds). Before, the parent was sent to the general list and had to find "Downloaded apps" and then OSRA.
- **"Allow calls and texts" disappears once it is granted.** The step used to render the button whenever capture was compiled in, and the permission result never re-rendered the screen, so a granted parent kept seeing the ask. Now the section shows only while a permission is missing, and the result re-renders the stage.
- **Overlay confirmation reads before trusting.** On a Xiaomi-family device, a parent's "I turned it on" tap is stored only while MIUI op `10021` is unreadable. A readable allow needs no confirmation and a readable **denial** can no longer be papered over by the tap — before, a parent who flipped only "Display pop-up windows" could get a green step while MIUI silently dropped the background start of `LockActivity`/`BlockActivity`.

Not in this PR: the pairing auto-focus finding (4) — there is no explicit focus request in the app, so the cause is the Compose host's focus handoff and the fix needs a device row; and the two wording items, which are the Bureaus'.
