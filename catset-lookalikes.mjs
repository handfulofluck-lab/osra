// Arabic look-alike row generator (K31-Mac, own-model data unit — Claude 7127335158).
//
// Boundary: this script never contains an Arabic glyph. Samples are built from codepoints and written as
// \uXXXX escapes, so a reviewer reads the structure without trusting a paste, and no shipped copy can be
// confused with data. Every row carries is_ui_text: false — the field that keeps these rows out of .strings/.arb.
//
// Usage: node catset-lookalikes.mjs > rows.jsonl

const FAMILIES = [
  {
    family: "alef-forms",
    why: "bare vs hamza forms; normalising all to bare alef hides a deliberate substitution",
    members: [0x0627, 0x0623, 0x0625, 0x0622, 0x0671],
  },
  {
    family: "yaa-vs-alef-maqsura",
    why: "word-final yaa and alef maqsura are visually near and semantically distinct",
    members: [0x064a, 0x0649, 0x06cc],
  },
  {
    family: "taa-marbuta-vs-haa",
    why: "word-final only; the substitution is invisible at small sizes",
    members: [0x0629, 0x0647],
  },
  {
    family: "kaf-variants",
    why: "Persian/Urdu kaf is a different letter; matters because the product ships Urdu",
    members: [0x0643, 0x06a9],
  },
  {
    family: "heh-variants",
    why: "Urdu heh goal is a letter, not a decoration",
    members: [0x0647, 0x06c1, 0x06d5],
  },
  {
    family: "digit-sets",
    why: "normalising digits is right for search and wrong for a verification code",
    members: [0x0660, 0x06f0, 0x0030],
  },
  {
    family: "tatweel",
    why: "elongation is zero-width-ish; stripping is usual, keeping it can defeat a naive match",
    members: [0x0640],
  },
  {
    family: "diacritics",
    why: "stripping is normal for search and lossy for quoted text",
    members: [0x064b, 0x064e, 0x0650, 0x0652, 0x0670],
  },
  {
    family: "zero-width",
    why: "invisible characters: the honest row is 'this string differs only by something you cannot see'",
    members: [0x200b, 0x200c, 0x200d, 0xfeff],
  },
  {
    family: "presentation-forms",
    why: "rendering forms that must normalise to their base letters",
    members: [0xfb50, 0xfb51, 0xfe70, 0xfe71],
  },
  {
    family: "arabic-punctuation",
    why: "punctuation that reads as Latin % , ; but is not them",
    members: [0x066a, 0x060c, 0x061b],
  },
];

const escape = (cp) => "\\u" + cp.toString(16).toUpperCase().padStart(4, "0");
const name = (cp) => `U+${cp.toString(16).toUpperCase().padStart(4, "0")}`;

let n = 0;
const rows = [];
for (const f of FAMILIES) {
  // One row per unordered pair inside a family: the smallest unit a detector can be wrong about.
  for (let i = 0; i < f.members.length; i++) {
    for (let j = i + 1; j < f.members.length; j++) {
      n += 1;
      rows.push({
        id: `ar-look-${String(n).padStart(4, "0")}`,
        family: f.family,
        samples: [escape(f.members[i]), escape(f.members[j])],
        codepoints: [name(f.members[i]), name(f.members[j])],
        relation: "visually-near",
        why: f.why,
        source: "unicode-codepoint-table",
        is_ui_text: false,
      });
    }
  }
  // A single-member family still earns a row: "this codepoint exists and is invisible/strippable".
  if (f.members.length === 1) {
    n += 1;
    rows.push({
      id: `ar-look-${String(n).padStart(4, "0")}`,
      family: f.family,
      samples: [escape(f.members[0])],
      codepoints: [name(f.members[0])],
      relation: "invisible-or-strippable",
      why: f.why,
      source: "unicode-codepoint-table",
      is_ui_text: false,
    });
  }
}

for (const r of rows) console.log(JSON.stringify(r));
console.error(`rows: ${rows.length} (families: ${FAMILIES.length})`);
