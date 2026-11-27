### Child agent — preserve manual server entry on unconfigured C-05 builds (#1208)
- `PairingServerFieldPolicy.useCodeOnlyC05Step` keeps the code-only C-05 pairing step for preset builds and scanned QR codes, while falling back to the existing manual form when an unconfigured build leaves the server field editable and blank.
