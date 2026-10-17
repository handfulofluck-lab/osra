/**
 * Device JWT lifetime (10 years, `ms`-style "10y" = 365.25-day years), in seconds. The SAME constant
 * bounds the `revoked:device:<id>` key written on unpair and on child erasure (#56): that key is what
 * turns a still-valid device token into `401 device_revoked` once the `Device` row is gone, so it must
 * outlive any token the device could present — never shorter than this, never reaped by cleanup. A key
 * written with this TTL expires no earlier than the last token minted before the revocation.
 */
export const DEVICE_TOKEN_TTL_SECONDS = Math.round(10 * 365.25 * 24 * 60 * 60); // 315 576 000
