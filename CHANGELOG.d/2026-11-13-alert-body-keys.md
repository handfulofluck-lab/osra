### API — alert bodies carry localization keys and parameters (#711)
- The five server-built alert shapes now store a shared `bodyKey` and typed `bodyParams` in the alert row's JSON metadata, so the parent app can own the rendered sentence without a database migration.
- The English `title` and `body` remain on every alert as the compatibility fallback for installed parent apps that do not know these keys yet; missing required parameters are refused before an alert row is written.
