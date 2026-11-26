# C-02 Android blocked screen

Source `df790aa3622238e78f02788e935fe715502d4488` from PR #1188. The debug fixture renders the shipped Compose screen and rule policy with synthetic inputs in an offline Android 15 emulator. The fixture reuses the shipped text resources and copy logic.

The 48 primary images cover English and Arabic, light and dark, 390 dp with standard text and 320 dp with 200% text, and the six requested states. The 16 additional images show the actions after scrolling at 320 dp. Waiting and Rules use the screen's actual tappable controls.

See `sha256.txt` and `frame-provenance.json` for file integrity and measured display settings.
