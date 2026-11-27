# C-03 Ask a parent follow-up for PR #1196

Head `fc32821a52f3c3ae198c7fcee4ea1ac9cd222236`. Captured 27 November 2026 at 06:45 UAE, on an isolated API 35 emulator in airplane mode. The FullDebug adapter uses the exact-head production screen, resource mapping and theme with fictional pending and failure states. Its host uses the same NoActionBar and edge-to-edge settings as the production activity. No request was sent.

| Frame | Reading |
|---|---|
| [English light 390 ask](c03_en_light_390_ask.png) | Native title bar absent. Choices, preview and Send request in one viewport. |
| [English dark 390 pending](c03_en_dark_390_pending.png) | Waiting state shows the time and recipient. |
| [English light 320 at 200%, send failed](c03_en_light_320_20_failed.png) | Scrolled to the bottom. Retry and all three footer lines are clear of the gesture bar. |
| [Arabic light 320 at 200%, send failed](c03_ar_light_320_20_failed.png) | Scrolled to the bottom. RTL retry and all three footer lines are clear of the gesture bar. |

The exact-head focused AskParentPolicyTest passed 5/5 in FullDebug and 5/5 in PlayDebug before the adapter was added. The emulator lease was released after capture.
