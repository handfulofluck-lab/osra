# UI/UX frames — P-22 Settings, final set for `92593bfb`

Rendered by CI from `k31mac/1179-frame-artifacts` at **12e95bcd**, which carries the P-22 head
**92593bfb** (run 45957364442, artifact ux-frames-aa72f0c7…).

Verify: `git diff --quiet 92593bfb 12e95bcd -- apps/parent-app/lib/features/settings/` (empty).

| File | What it shows |
|---|---|
| `p22-menu-on-en-light-390.png` | Dashboard menu with `OSRA_UX_P22` on: **Family members**, **Settings** |
| `p22-menu-off-en-light-390.png` | The same menu with the flag off: Family members, Appearance, Digest preferences, Two-step verification, Delete account — unchanged |
| `p22-settings-en-light-390.png` | Language English, Appearance Light, Time zone UTC+4, two-step On, recovery codes, digest, delete account in red |
| `p22-settings-ar-dark-390.png` | The same in Arabic, dark |
| `p22-settings-card-shown-en-light-390.png` / `-ar-dark-390.png` | Security card shown (two-step off) |
| `p22-settings-en-light-320-200.png` / `p22-settings-ar-dark-320-200.png` | 320 px / 200 %, values wrap under their labels |
| `p22-settings-signout-dialog-en-light-390.png` | Sign out of all devices? — Cancel (default) and Sign out everywhere in the error colour |
| `p22-settings-flag-off-en-light-390.png` | The screen with the provider false; identical by design — the flag gates the route, and the menu frames above show what changes |
| `p17-social-*.png` (4) | P-17 Social monitoring at head 8b330fab, unchanged |

The red corner mark is Flutter's debug banner from the test renderer, not app UI.
