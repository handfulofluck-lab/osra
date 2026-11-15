### API — non-destructive parent reauthentication (#774, #742)
- `POST /v1/auth/reauth` accepts a live parent session and the existing password plus current-TOTP proof, returning only 204 on success without creating a session/token or changing `lastLoginAt`.
- Invalid proof and auth-rate-limit refusal share a uniform 401. The session-`jti` failure counter uses atomic Redis `INCR`+TTL; failure 5 and every later failed proof retry revocation until it succeeds, removing the current access token and its associated live refresh record. Structured `parent_reauth` logs exclude proof material, IP and device names.
- This is the API slice only. Parent-app wiring, client biometric verification, native evidence and Arabic-digit integration after #787 remain open before readiness.
