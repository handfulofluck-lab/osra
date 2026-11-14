// The OSRA logo, "Embrace" (chosen by the maintainer on 2026-11-12): the O of OSRA as a parent's arm around a
// child; the dot is the child. This file is the one source of the mark. It writes the master SVGs to
// docs/design/brand/ and every raster size to docs/design/brand/export/. Colours are tokens from
// docs/design/tokens.json (ADR-0038). Usage: NODE_PATH=$(npm root -g) node scripts/brand/render.mjs
// Needs Playwright with Chromium, and ffmpeg (to drop the alpha channel where a store refuses one).
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const OUT = join(ROOT, "docs/design/brand");
const tokens = JSON.parse(readFileSync(join(ROOT, "docs/design/tokens.json"), "utf8"));
const c = tokens.color;

// The mark in a 100 x 100 box: a 270-degree ring (radius 26, stroke 12, round ends) open at the top right,
// and a dot of radius 7.5 in the opening. It sits inside the middle 66% so every platform mask keeps it whole.
export const MARK = { ring: "M76 50 A26 26 0 1 1 50 24", ringWidth: 12, dot: { cx: 68.4, cy: 31.6, r: 7.5 } };
const mark = (ring, dot) =>
  `<path d="${MARK.ring}" fill="none" stroke="${ring}" stroke-width="${MARK.ringWidth}" stroke-linecap="round"/>` +
  `<circle cx="${MARK.dot.cx}" cy="${MARK.dot.cy}" r="${MARK.dot.r}" fill="${dot}"/>`;

// One mark, three apps. Parent: solid Calm primary. OSRA Kids: the light tint. OSRA Kids Full: dark.
export const APPS = {
  parent: { name: "OSRA", bg: c.primary.light, ring: c.onPrimary.light, dot: c.warn.dark },
  kids: { name: "OSRA Kids", bg: c.tint.light, ring: c.primary.light, dot: tokens.usageCategory.games.light },
  "kids-full": { name: "OSRA Kids Full", bg: c.ink.light, ring: c.ok.dark, dot: c.warn.dark },
};

const svg = (inner, title) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="${title}">${inner}</svg>\n`;
const square = (a) => svg(`<rect width="100" height="100" fill="${a.bg}"/>${mark(a.ring, a.dot)}`, `${a.name} icon`);
// Legacy Android and Windows: the square with a small radius. Mac: Apple's rounded square inset in its canvas.
const rounded = (a, r) => svg(`<rect width="100" height="100" rx="${r}" fill="${a.bg}"/>${mark(a.ring, a.dot)}`, `${a.name} icon`);
const mac = (a) => svg(`<g transform="translate(10 10) scale(0.8)"><rect width="100" height="100" rx="22.5" fill="${a.bg}"/>${mark(a.ring, a.dot)}</g>`, `${a.name} icon`);
const circle = (a) => svg(`<circle cx="50" cy="50" r="50" fill="${a.bg}"/>${mark(a.ring, a.dot)}`, `${a.name} icon`);

mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, "mark.svg"), svg(mark(c.primary.light, tokens.usageCategory.games.light), "OSRA"));
writeFileSync(join(OUT, "mark-dark.svg"), svg(mark(c.primary.dark, c.warn.dark), "OSRA"));
for (const [id, a] of Object.entries(APPS)) writeFileSync(join(OUT, `icon-${id}.svg`), square(a));

const { chromium } = createRequire(import.meta.url)("playwright");
const browser = await chromium.launch();
const page = await (await browser.newContext({ deviceScaleFactor: 1 })).newPage();
async function png(markup, size, file, { opaque = false } = {}) {
  mkdirSync(dirname(file), { recursive: true });
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${markup}`);
  await page.screenshot({ path: file, omitBackground: true });
  if (opaque) { // App Store and Play icons must carry no alpha channel
    execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", file, "-pix_fmt", "rgb24", file + ".tmp.png"]);
    writeFileSync(file, readFileSync(file + ".tmp.png")); rmSync(file + ".tmp.png");
  }
}
// ICO with PNG-compressed images (Windows Vista and later).
function ico(files, out) {
  const imgs = files.map(([size, f]) => [size, readFileSync(f)]);
  const head = Buffer.alloc(6 + 16 * imgs.length); head.writeUInt16LE(1, 2); head.writeUInt16LE(imgs.length, 4);
  let offset = head.length;
  imgs.forEach(([size, data], i) => {
    const e = 6 + 16 * i; head.writeUInt8(size >= 256 ? 0 : size, e); head.writeUInt8(size >= 256 ? 0 : size, e + 1);
    head.writeUInt16LE(1, e + 4); head.writeUInt16LE(32, e + 6); head.writeUInt32LE(data.length, e + 8); head.writeUInt32LE(offset, e + 12);
    offset += data.length;
  });
  writeFileSync(out, Buffer.concat([head, ...imgs.map(([, d]) => d)]));
}

const IOS = [["20x20", 1], ["20x20", 2], ["20x20", 3], ["29x29", 1], ["29x29", 2], ["29x29", 3], ["40x40", 1], ["40x40", 2], ["40x40", 3],
  ["60x60", 2], ["60x60", 3], ["76x76", 1], ["76x76", 2], ["83.5x83.5", 2], ["1024x1024", 1]];
const ANDROID = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
let count = 0;
for (const [id, a] of Object.entries(APPS)) {
  const dir = join(OUT, "export", id);
  rmSync(dir, { recursive: true, force: true });
  await png(square(a), 1024, join(dir, "icon-1024.png"), { opaque: true }); count++;
  await png(square(a), 512, join(dir, "store-512.png"), { opaque: true }); count++;
  for (const [pt, scale] of IOS) { // full-bleed squares; iOS rounds the corners itself
    await png(square(a), Math.round(parseFloat(pt) * scale), join(dir, "ios", `Icon-App-${pt}@${scale}x.png`), { opaque: true }); count++;
  }
  for (const [density, size] of Object.entries(ANDROID)) { // pre-API-26 launchers; newer ones use the adaptive XML
    await png(rounded(a, 18), size, join(dir, "android", `mipmap-${density}`, "ic_launcher.png")); count++;
    await png(circle(a), size, join(dir, "android", `mipmap-${density}`, "ic_launcher_round.png")); count++;
  }
  const winSizes = [16, 24, 32, 48, 64, 256];
  for (const s of winSizes) { await png(rounded(a, 12), s, join(dir, "windows", `icon-${s}.png`)); count++; }
  ico(winSizes.map((s) => [s, join(dir, "windows", `icon-${s}.png`)]), join(dir, "windows", "app.ico")); count++;
  for (const s of [16, 32, 64, 128, 256, 512, 1024]) { await png(mac(a), s, join(dir, "mac", `icon-${s}.png`)); count++; }
}
await browser.close();
console.log(`brand: 5 SVG masters and ${count} exported files in docs/design/brand`);
