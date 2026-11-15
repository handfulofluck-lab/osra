import { describe, expect, it } from "vitest";
import { digestEmail, inviteEmail, type DigestChild } from "../src/lib/email/templates.js";

const link = "https://example.invalid/invite/accept?token=synthetic";
const noBidi = (value: string) => value.replace(/[\u2068\u2069]/g, "");

function invite(inviterName: string | null, familyName: string | null, role = "co-parent") {
  return inviteEmail("parent@example.invalid", { inviterName, familyName, role, link });
}

function child(totalAppMinutes: number): DigestChild {
  return {
    displayName: "Alex",
    totalAppMinutes,
    topApps: [],
    urlVisits: 0,
    topBlockedDomains: [],
    socialConcerns: 0,
    calls: 0,
    sms: 0,
  };
}

describe("localized invitation text", () => {
  it.each([
    {
      inviter: "Sara", family: "Haddad",
      en: "Sara invited you to the Haddad family on OSRA",
      ar: "دعوة من Sara للانضمام إلى عائلة Haddad في تطبيق أسرة",
    },
    {
      inviter: null, family: "Haddad",
      en: "You have been invited to the Haddad family on OSRA",
      ar: "دعوة للانضمام إلى عائلة Haddad في تطبيق أسرة",
    },
    {
      inviter: "Sara", family: null,
      en: "Sara invited you to a family on OSRA",
      ar: "دعوة من Sara للانضمام إلى عائلة في تطبيق أسرة",
    },
    {
      inviter: null, family: null,
      en: "You have been invited to a family on OSRA",
      ar: "دعوة للانضمام إلى عائلة في تطبيق أسرة",
    },
  ])("handles both names without a fallback leak: $en", ({ inviter, family, en, ar }) => {
    const message = invite(inviter, family);
    expect(noBidi(message.text)).toContain(en);
    expect(noBidi(message.text)).toContain(ar);
    expect(message.text).not.toContain("the your");
    expect(message.text).not.toContain("A parent");
    expect(message.text).not.toContain("null");
    if (inviter || family) expect(message.html).toContain("<bdi>");
    else expect(message.html).not.toContain("<bdi>");
    expect(message.text).not.toContain("<bdi>");
  });

  it("isolates Latin inviter and family names in HTML and plain text", () => {
    const message = invite("Sara", "Haddad");
    expect(message.html).toContain("<bdi>Sara</bdi>");
    expect(message.html).toContain("<bdi>Haddad</bdi>");
    expect(message.text).toContain("\u2068Sara\u2069");
    expect(message.text).toContain("\u2068Haddad\u2069");
  });

  it("uses the whole Arabic guardian sentence with no Latin role wire value", () => {
    const message = invite("Sara", "Haddad", "guardian");
    const roleLine = message.text.split("\n").find((line) => line.startsWith("تمت دعوتك"));
    expect(roleLine).toBe("تمت دعوتك بصفة ولي أمر. اقبل الدعوة لمتابعة الأطفال والتنبيهات وأدوات التحكم من حسابك.");
    expect(roleLine).not.toMatch(/[A-Za-z]/);
  });

  it("uses the generic whole sentence for an unknown role", () => {
    const message = invite("Sara", "Haddad", "future-role");
    expect(message.text).toContain("تمت دعوتك للانضمام إلى العائلة. اقبل الدعوة لمتابعة الأطفال والتنبيهات وأدوات التحكم من حسابك.");
    expect(message.text).not.toContain("future-role");
  });
});

describe("localized digest text", () => {
  it.each([
    [0, "لا شيء"],
    [1, "دقيقة واحدة"],
    [2, "دقيقتان"],
    [5, "5 دقائق"],
    [11, "11 دقيقة"],
    [100, "100 دقيقة"],
  ])("formats screen time %i with the Bureau's Arabic plural row", (minutes, expected) => {
    const message = digestEmail("parent@example.invalid", {
      familyName: "Demo", days: 1, link, children: [child(minutes)],
    }, "ar");
    expect(message.text).toContain(`وقت الشاشة: ${expected}`);
  });

  it.each([
    [0, "أقل من دقيقة"],
    [1, "دقيقة واحدة"],
    [2, "دقيقتان"],
  ])("uses whole words for an app's %i minutes", (minutes, expected) => {
    const message = digestEmail("parent@example.invalid", {
      familyName: "Demo", days: 1, link,
      children: [{ ...child(0), topApps: [{ name: "YouTube", minutes }] }],
    }, "ar");
    expect(noBidi(message.text)).toContain(`YouTube ${expected}`);
  });

  it.each([
    [1, "ملخّص عائلة Demo من تطبيق أسرة: اليوم"],
    [2, "ملخّص عائلة Demo من تطبيق أسرة: آخر يومين"],
    [7, "ملخّص عائلة Demo من تطبيق أسرة: آخر 7 أيام"],
    [11, "ملخّص عائلة Demo من تطبيق أسرة: آخر 11 يومًا"],
    [100, "ملخّص عائلة Demo من تطبيق أسرة: آخر 100 يوم"],
  ])("formats the digest period for %i days", (days, expected) => {
    const message = digestEmail("parent@example.invalid", {
      familyName: "Demo", days, link, children: [], }, "ar");
    expect(noBidi(message.text.split("\n")[0])).toBe(expected);
  });

  it("uses the label form for every zero count and no plural noun after a number", () => {
    const message = digestEmail("parent@example.invalid", {
      familyName: "Demo", days: 1, link, children: [child(0)], }, "ar");
    expect(noBidi(message.text)).toContain(
      "Alex — وقت الشاشة: لا شيء؛ أكثر التطبيقات استخدامًا: لا يوجد؛ المواقع التي فُتحت: 0؛ المواقع المحجوبة: 0؛ تنبيهات وسائل التواصل الاجتماعي: 0؛ المكالمات: 0؛ الرسائل النصية: 0.",
    );
  });

  it("uses the busy-child line and isolates child and app names", () => {
    const message = digestEmail("parent@example.invalid", {
      familyName: "Demo",
      days: 7,
      link,
      children: [{
        ...child(5),
        topApps: [{ name: "YouTube", minutes: 45 }],
        urlVisits: 44,
        topBlockedDomains: [{ domain: "bad.example", count: 3 }],
        socialConcerns: 2,
        calls: 3,
        sms: 4,
      }],
    }, "ar");
    expect(noBidi(message.text)).toContain(
      "Alex — وقت الشاشة: 5 دقائق؛ أكثر التطبيقات استخدامًا: YouTube 45 دقيقة؛ المواقع التي فُتحت: 44؛ المواقع المحجوبة: 1؛ تنبيهات وسائل التواصل الاجتماعي: 2؛ المكالمات: 3؛ الرسائل النصية: 4.",
    );
    expect(message.html).toContain("<bdi>Alex</bdi>");
    expect(message.html).toContain("<bdi>YouTube</bdi>");
    expect(message.text).toContain("\u2068Alex\u2069");
    expect(message.text).toContain("\u2068YouTube\u2069");
  });

  it("uses real English singular and plural forms without concern(s)", () => {
    const one = digestEmail("parent@example.invalid", {
      familyName: "Demo", days: 2, link,
      children: [{ ...child(1), urlVisits: 1, socialConcerns: 1, calls: 1, sms: 1 }],
    }, "en");
    expect(one.text).toContain("the last 2 days");
    expect(one.text).toContain("1 site visited");
    expect(one.text).toContain("1 social concern;");
    expect(one.text).toContain("1 call, 1 SMS");
    expect(one.text).not.toContain("concern(s)");

    const two = digestEmail("parent@example.invalid", {
      familyName: "Demo", days: 2, link,
      children: [{ ...child(2), urlVisits: 2, socialConcerns: 2, calls: 2, sms: 2 }],
    }, "en");
    expect(two.text).toContain("2 sites visited");
    expect(two.text).toContain("2 social concerns");
    expect(two.text).toContain("2 calls, 2 SMS");
  });
});
