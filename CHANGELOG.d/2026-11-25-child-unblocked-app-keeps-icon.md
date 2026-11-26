### iPhone child — an unblocked app keeps its icon (#1090)
- `blockedApplications` does not block an app: iOS removes it from the Home Screen and the App Library, so
  a child looking for the blocked app finds it moved rather than stopped, and un-hiding it later puts it
  back in the App Library instead of where it was.
- Hiding is now the fallback only for an app Screen Time gave no token for, decided per app: the apps that
  resolved are shielded and keep their icons, and the rest are hidden because no shield can cover them.
