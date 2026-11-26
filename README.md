# P-09 Apps Bureau frames

Source `e690116efe735ae4d6e1fbc2c750068f9bb78edd` from PR #1182. Parent source tree `a261602211f13dda766c9c47087b6ecc26e2ecb2`.

Ten headless Flutter widget captures use synthetic app reports, the production Apps route and the shipped P-09 provider override set to on. The rendered images match the earlier PNG hashes byte for byte. All 24 checks passed, including the explicit flag-off legacy switch and choice-sheet test.

Frames cover English and Arabic, light and dark, 393 px and 320 px at 200% text, the time-limit sheet and the Arabic iPhone card. At 393 px the available row width is 361 px, below the 380 px inline threshold. Actions stack and remain visible at 320 px and 200% text.

See sha256.txt for image integrity.
