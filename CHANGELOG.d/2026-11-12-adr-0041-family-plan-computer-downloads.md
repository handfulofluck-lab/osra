### Architecture — one family plan on every platform; Windows and Mac clients from osratech.com (ADR-0041)
- ADR-0041 (proposed): a plan bought on Google Play or the App Store covers every child and device on
  Android, iPhone, Windows and Mac; the server computes the entitlement from verified store purchases.
- The Windows and Mac clients are downloaded from `osratech.com/windows` and `/mac`, pair from the parent
  app with no server field, and update from an offline-signed manifest.
- Roadmap 5.4 rewritten (service + tray, DNS filter, signed MSI instead of MSIX), 5.9 made launch scope,
  new rows 5.12 (family plan) and 5.13 (download pages); ADR-0036 build rule 4 amended.
