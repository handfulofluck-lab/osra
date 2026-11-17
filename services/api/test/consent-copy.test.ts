import { createHash } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import { consentCopyRoutes } from "../src/routes/consentCopy.js";
import { buildApp } from "./helpers.js";

/**
 * ADR-0043 D3 / #846 part A: `GET /v1/consent-copy?locale=` is the one place the sign-up wording lives.
 *
 * The two texts below are pinned literals, the same way the Arabic ARB pins are: counsel's A1 English and
 * the Arabic Language Bureau's line from #846 (comment 6923432616), byte for byte, with the two Arabic
 * URLs the Bureau's labels point at. If a later edit changes either text, the hash changes with it — and
 * that is correct, because a changed text is a new `textVersion`, not a silent edit.
 */
const ENGLISH_BOX =
  "I am an adult and the parent, legal guardian or other person legally allowed to care for each child I add to OSRA. I accept the OSRA [Terms of Use](https://osratech.com/terms) and I have read the [Privacy Policy](https://osratech.com/privacy).";

const ARABIC_BOX =
  "أُقرّ بأنني بلغت سن الرشد، وبأنني أحد والدَي كل طفل أضيفه إلى تطبيق أسرة أو وصيّه القانوني أو شخص آخر مخوّل قانونًا برعايته. وأقبل [شروط استخدام تطبيق أسرة](https://osratech.com/ar/terms)، وقد قرأت [سياسة الخصوصية](https://osratech.com/ar/privacy).";

const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");

describe("GET /v1/consent-copy", () => {
  let app: Awaited<ReturnType<typeof buildApp>>;

  beforeAll(async () => {
    app = await buildApp(consentCopyRoutes, "/v1");
  });

  it("serves box 1 in English with no session, at the version counsel issued", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/consent-copy?locale=en" });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.textVersion).toBe("signup-v1");
    expect(body.locale).toBe("en");
    expect(body.purposes).toHaveLength(1);
    const [box] = body.purposes;
    expect(box).toMatchObject({
      key: "terms_privacy",
      required: true,
      text: ENGLISH_BOX,
      textHash: sha256(ENGLISH_BOX),
      links: { terms: "https://osratech.com/terms", privacy: "https://osratech.com/privacy" },
    });
    // The app renders the links as buttons, so the markdown has to carry both URLs.
    expect(box.text).toContain("[Terms of Use](https://osratech.com/terms)");
    expect(box.text).toContain("[Privacy Policy](https://osratech.com/privacy)");
    // Configuring it as a cacheable body would serve a stale version after a `textVersion` bump.
    expect(res.headers["cache-control"]).toBe("no-store");
  });

  it("serves the Bureau's Arabic byte for byte, with the Arabic pages linked", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/consent-copy?locale=ar" });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.locale).toBe("ar");
    const [box] = body.purposes;
    expect(box.text).toBe(ARABIC_BOX);
    expect(box.textHash).toBe(sha256(ARABIC_BOX));
    expect(box.links).toEqual({ terms: "https://osratech.com/ar/terms", privacy: "https://osratech.com/ar/privacy" });
    // The Bureau's instruction: copy byte for byte, "no hidden direction marks".
    expect(/[‎‏؜]/.test(box.text)).toBe(false);
  });

  it("falls back to English for a locale it does not serve, and says which one it served", async () => {
    for (const locale of ["fr", "ur", ""]) {
      const res = await app.inject({ method: "GET", url: `/v1/consent-copy?locale=${locale}` });
      expect(res.statusCode).toBe(200);
      expect(res.json().locale).toBe("en");
      expect(res.json().purposes[0].text).toBe(ENGLISH_BOX);
    }
  });

  it("serves English when the locale is missing altogether", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/consent-copy" });
    expect(res.statusCode).toBe(200);
    expect(res.json().locale).toBe("en");
  });

  it("offers only the one purpose the amendment kept", async () => {
    const body = (await app.inject({ method: "GET", url: "/v1/consent-copy?locale=en" })).json();
    const keys = body.purposes.map((purpose: { key: string }) => purpose.key);
    // The marketing purpose was removed and the training one is parked (ADR-0043 amendment, A2/A8):
    // a copy that offered them would describe choices the server refuses.
    expect(keys).toEqual(["terms_privacy"]);
    expect(JSON.stringify(body)).not.toContain("marketing");
    expect(JSON.stringify(body)).not.toContain("ai_improvement");
  });

  it("answers a locale header case-insensitively and never with a raw error", async () => {
    for (const locale of ["AR", "ar-EG", "ar_SA"]) {
      const res = await app.inject({ method: "GET", url: `/v1/consent-copy?locale=${locale}` });
      expect(res.statusCode).toBe(200);
      expect(res.json().locale).toBe("ar");
    }
  });
});
