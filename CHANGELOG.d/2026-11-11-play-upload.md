### CI — bundles can go to Google Play testing tracks from Actions (roadmap 5.2/5.7)
- New `Play upload` workflow (manual only) sends the signed bundle of a green `child-android` or `parent-app` run to the internal, alpha or beta track through the Play Developer API. Production is not offered.
- `check` mode proves the `PLAY_SERVICE_ACCOUNT_JSON` key works without changing anything; `validate` uploads and discards.
- `scripts/play-upload.mjs` signs the service-account token with `node:crypto` and calls the API with `fetch`, so no third-party action holds the key.
