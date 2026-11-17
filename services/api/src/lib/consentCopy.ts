import { createHash } from "node:crypto";

/**
 * ADR-0043 D3/D4: the sign-up consent copy, served by the API so the wording and the version that is
 * recorded against it live in one place. The app renders what this returns; it carries no legal text of
 * its own, which is what makes `textHash` mean something (#846 part A).
 *
 * **Box 1 only, deliberately.** Counsel's 16 Nov amendment (A2, A8/C19) removed the marketing purpose and
 * parks the training one until its evidence exists, so a copy that offered three boxes would describe
 * choices the server refuses. When the training switch-on is decided, it becomes a second entry here with
 * its own key and its own `textVersion`, not a change to this one.
 *
 * The texts are the ones issued by counsel (A1, ADR-0043 `signup-v1`) and the Arabic Language Bureau
 * (#846 comment 6923432616), byte for byte. The two Arabic URLs are the Arabic pages the Bureau's link
 * labels point at, the same pair the parent app's tests already pin.
 */
export const CONSENT_TEXT_VERSION = "signup-v1";

type CopyLocale = "en" | "ar";

interface CopyEntry {
  text: string;
  links: { terms: string; privacy: string };
}

const COPY: Record<CopyLocale, CopyEntry> = {
  en: {
    text:
      "I am an adult and the parent, legal guardian or other person legally allowed to care for each child I add to OSRA. I accept the OSRA [Terms of Use](https://osratech.com/terms) and I have read the [Privacy Policy](https://osratech.com/privacy).",
    links: { terms: "https://osratech.com/terms", privacy: "https://osratech.com/privacy" },
  },
  ar: {
    text:
      "أُقرّ بأنني بلغت سن الرشد، وبأنني أحد والدَي كل طفل أضيفه إلى تطبيق أسرة أو وصيّه القانوني أو شخص آخر مخوّل قانونًا برعايته. وأقبل [شروط استخدام تطبيق أسرة](https://osratech.com/terms)، وقد قرأت [سياسة الخصوصية](https://osratech.com/privacy).",
    links: { terms: "https://osratech.com/terms", privacy: "https://osratech.com/privacy" },
  },
};

/** SHA-256 of the exact text served, lowercase hex — the value a consent row records (ADR-0043 D1). */
export function consentTextHash(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

export interface ConsentCopy {
  textVersion: string;
  /** The locale actually served: an unsupported request falls back to English, and says so. */
  locale: CopyLocale;
  purposes: Array<{
    key: "terms_privacy";
    required: true;
    text: string;
    textHash: string;
    links: { terms: string; privacy: string };
  }>;
}

/**
 * The copy for one requested locale. Only the two locales the app ships are served; a request for any
 * other language gets English and `locale: "en"`, rather than an error — a sign-up page that cannot read
 * the terms is worse than one that shows them in the default language (ADR-0042 adds locales here).
 */
export function consentCopyFor(requested: string | undefined): ConsentCopy {
  const locale: CopyLocale = (requested ?? "").trim().toLowerCase().startsWith("ar") ? "ar" : "en";
  const entry = COPY[locale];
  return {
    textVersion: CONSENT_TEXT_VERSION,
    locale,
    purposes: [
      {
        key: "terms_privacy",
        required: true,
        text: entry.text,
        textHash: consentTextHash(entry.text),
        links: entry.links,
      },
    ],
  };
}
