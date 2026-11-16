### Parent app — the excerpt vault no longer claims device-side family-key encryption
- `vaultTrustCopy` said excerpts are "encrypted with your family key before leaving the device". The
  server does the encryption (`services/api/src/routes/social.ts` calls `encryptSnippet` after receipt),
  so the line now reads "Excerpts travel over an encrypted connection and are stored encrypted on OSRA's
  servers.", matching privacy policy sections 4 and 13 (pack document 09 A7). English only; the Arabic
  string is the Arabic Language Bureau's to re-issue.
