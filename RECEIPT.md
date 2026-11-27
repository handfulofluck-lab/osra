# MIUI permission confirmation for PR #1248

Head `501991ebd117b4321460d03097b13189649fb8c2`. Captured 27 November 2026 at 08:11 UAE on an isolated Android API 35 emulator in airplane mode. The FullDebug display fixture uses the production permission screen, the exact resource mapping and inert callbacks. It shows the fixed confirmation state without changing system permissions.

- [EN light 390 at 100%](miui_confirm_en_light_390_10.png) shows the explanation, grant action, confirmation hint, confirmation button and checklist link.
- [AR light 320 at 200%](miui_confirm_ar_light_320_20.png) shows the complete confirmation hint and both actions. The fixed action region fills the viewport and leaves the general heading and explanation out of view.

The exact focused policy suite passed 5/5 in FullDebug and 5/5 in PlayDebug before adding the display fixture. The emulator lease was released after capture.
