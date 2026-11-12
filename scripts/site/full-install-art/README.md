# Install drawings and video for osratech.com/android (ADR-0039 PR E)

`scenes.html` draws each install step (EN and AR) and animates it; `render.mjs` turns it into
`site/android/img/<scene>-<lang>.webp` and `site/android/video/install-<lang>.mp4` (+ poster).

```bash
# fonts: Nunito 400/800 (latin) and Noto Sans Arabic 400/800 (arabic) woff2 from @fontsource, in one folder
NODE_PATH=$(npm root -g) FONT_DIR=/path/to/fonts node scripts/site/full-install-art/render.mjs "$PWD"
```

Needs Playwright with Chromium and ffmpeg. The drawings are illustrations, not screenshots: Android's own
wording differs by version and maker, so the page text names the buttons and the drawings show where they
are. Change the wording in `scenes.html` (both languages) and re-render; never edit the images by hand.
