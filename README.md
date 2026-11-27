# UI/UX frames — P-22 Settings (final set for `d18eeae4`)

Rendered by CI from `k31mac/1179-frame-artifacts` at **f306a34e**, which carries the P-22 head
**d18eeae4**. Run 45949966785, artifact ux-frames-7fee5c89…

Verify the screen: `git diff --quiet d18eeae4 f306a34e -- apps/parent-app/lib/features/settings/` (empty).

| File | What it shows |
|---|---|
| `p22-settings-en-light-390.png` | Language English, Appearance Light, Time zone UTC+4, two-step On, recovery codes, digest, delete account in red |
| `p22-settings-ar-dark-390.png` | The same in Arabic, dark |
| `p22-settings-card-shown-en-light-390.png` | Security card shown (two-step off) |
| `p22-settings-card-shown-ar-dark-390.png` | The card in Arabic, dark |
| `p22-settings-en-light-320-200.png` | 320 px / 200 %, values wrap under their labels |
| `p22-settings-ar-dark-320-200.png` | The same in Arabic (new: the set previously had 320/200 only in EN) |
| `p22-settings-signout-dialog-en-light-390.png` | **Sign out of all devices?** — Cancel (default, left) and Sign out everywhere in the error colour |
| `p22-settings-flag-off-en-light-390.png` | The screen with `OSRA_UX_P22` false. Byte-identical to the flag-on frame **by design**: the flag gates navigation, not the screen |
| `p17-social-*.png` (4) | P-17 Social monitoring at head 8b330fab, unchanged |

The red corner mark is Flutter's debug banner from the test renderer, not app UI.
