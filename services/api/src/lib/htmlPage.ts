import type { FastifyReply } from "fastify";

/**
 * The pages the API serves itself (#442 PR 3 account deletion, #789 mailed links). English and Arabic on
 * every page, the Arabic block right-to-left. No script, nothing loaded from another origin, and nothing
 * user-supplied is rendered: a dynamic value is checked against its own pattern first and escaped anyway.
 */

export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// ADR-0038 light values, copied from docs/design/tokens.json (UI/UX Bureau, #804). The fonts stay the
// system stack: these pages load nothing from another origin.
/** The primary action. Also the safe one: cancelling an MFA reset keeps the account as it is. */
export const PRIMARY = "#0B5D57";
/** Destructive actions only (delete account). */
export const DANGER = "#A3242B";
export const CARD = "background:#fff;border-radius:18px;padding:24px;margin-top:16px";
export const BUTTON = "border:0;padding:12px 18px;min-height:52px;border-radius:12px;font-family:inherit;font-size:16px;color:#fff";
export const INPUT = "display:block;width:100%;box-sizing:border-box;padding:10px;margin:4px 0 12px;font-family:inherit;font-size:16px;border:1px solid #C9D6D3;border-radius:12px";

export function page(en: string, ar: string): string {
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>OSRA · أسرة</title></head>
<body style="margin:0;background:#F1F5F4;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#12211F">
  <div style="max-width:560px;margin:0 auto;padding:8px 16px 24px">
    <p style="margin:16px 4px 0;font-size:17px;font-weight:700;color:${PRIMARY}">OSRA · أسرة</p>
    <div lang="en" dir="ltr" style="${CARD}">${en}</div>
    <div lang="ar" dir="rtl" style="${CARD}">${ar}</div>
  </div>
</body>
</html>`;
}

export const h = (text: string) => `<h2 style="margin:0 0 12px;font-size:20px">${text}</h2>`;
export const p = (text: string) => `<p style="margin:0 0 12px;line-height:1.5">${text}</p>`;
export const err = (text: string | undefined) =>
  text ? `<p role="alert" style="margin:0 0 12px;padding:10px;border-radius:6px;background:#fdecea;color:#8a1c12;line-height:1.5">${text}</p>` : "";

/**
 * Every page: never cached (the confirm page holds the token in its form), never sent as a referrer,
 * never framed (a framed delete button is a clickjacking target), and no script at all.
 */
export function sendPage(reply: FastifyReply, status: number, html: string): FastifyReply {
  return reply
    .code(status)
    .type("text/html; charset=utf-8")
    .header("cache-control", "no-store")
    .header("referrer-policy", "no-referrer")
    .header("x-content-type-options", "nosniff")
    // Both forms of "never framed": `frame-ancestors` for current browsers, the older header for the rest.
    .header("x-frame-options", "DENY")
    .header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    )
    .send(html);
}
