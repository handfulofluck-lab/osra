# Lock and Pause internet follow-up for PR #1240

Head `75e6f1662c722e6d59887c2d47e75b66601d20ef`. Captured 27 November 2026 at 06:49 UAE on an isolated Android API 35 emulator in airplane mode. The FullDebug fixture uses the production lock renderer and paused-notification builder with local sample data. The fixture opens no apps and makes no network or policy changes.

| Frame | Reading |
|---|---|
| [English dark 390](lock_en_dark_390.png) | Lock title and three Always allowed shortcuts. |
| [English dark 320 at 200%](lock_en_dark_320_20.png) | Scrolled to all three shortcuts. Long label wraps to three lines. |
| [Arabic dark 390](lock_ar_dark_390.png) | RTL lock title and three Always allowed shortcuts. |
| [Arabic dark 320 at 200%](lock_ar_dark_320_20.png) | Scrolled to all three shortcuts. Long app label retains its original English wording. |
| [English notification, expanded](notice_en_390.png) | Full paused-internet message in the native shade. |
| [Arabic notification, expanded](notice_ar_390.png) | Full Arabic message in the native shade. Emulator system chrome is English. |

The exact-head focused `PauseInternetAndLockAllowlist1183Test` passed 6/6 FullDebug and 6/6 PlayDebug before the adapter was added. These are emulator layout frames and a fixture notification. The emulator lease was released after capture.
