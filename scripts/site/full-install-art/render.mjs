// ADR-0039 PR E: renders the install drawings and the walk-through video for osratech.com/android from
// scenes.html, in the site's own IBM Plex fonts (site/fonts) and the Calm tokens. Usage: node render.mjs <repo root>
// Writes site/android/img/<scene>-<lang>.webp and site/android/video/install-<lang>.mp4 (needs ffmpeg).
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright"); // global install in CI images; NODE_PATH=$(npm root -g)
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, rmSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = process.argv[2];
if (!root) throw new Error("usage: node render.mjs <repo root>");
const fontDir = join(root, "site/fonts");
const imgDir = join(root, "site/android/img");
const vidDir = join(root, "site/android/video");
const tmp = join(here, ".tmp");
for (const d of [imgDir, vidDir, tmp]) mkdirSync(d, { recursive: true });

const STILLS = ["s1", "s2", "s3", "s4", "s5", "s6", "s7"];
const DWELL = { title: 3200, end: 3200 };
const SCENE_MS = 4600;

async function route(page) {
  await page.route("https://art.local/**", (r) => {
    const p = new URL(r.request().url()).pathname;
    if (p.startsWith("/fonts/")) return r.fulfill({ body: readFileSync(join(fontDir, p.slice(7))), contentType: "font/woff2" });
    return r.fulfill({ body: readFileSync(join(here, "scenes.html")), contentType: "text/html" });
  });
}

const browser = await chromium.launch();
for (const lang of ["en", "ar"]) {
  // Stills: the phone(s) only; the page's own step text is the caption.
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1.5 });
  const page = await ctx.newPage();
  await route(page);
  for (const id of STILLS) {
    await page.goto(`https://art.local/scenes.html?lang=${lang}&still=1&scene=${id}`);
    await page.waitForSelector("body[data-ready='1']");
    await page.waitForTimeout(150);
    const b = await page.locator(`#${id} .holder`).boundingBox();
    const png = join(tmp, `${id}-${lang}.png`);
    await page.screenshot({ path: png, clip: { x: b.x - 30, y: b.y - 56, width: b.width + 60, height: b.height + 86 } });
    execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", png, "-vf", "scale=iw/1.5*1.0:-1", "-quality", "82", join(imgDir, `${id}-${lang}.webp`)]);
  }
  await ctx.close();

  // Video: every scene in order; a 1600x900 page recorded at 1280x720 so two phones and the caption fit.
  const vctx = await browser.newContext({ viewport: { width: 1600, height: 900 }, recordVideo: { dir: tmp, size: { width: 1280, height: 720 } } });
  const vp = await vctx.newPage();
  await route(vp);
  await vp.goto(`https://art.local/scenes.html?lang=${lang}`);
  await vp.waitForSelector("body[data-ready='1']");
  const ids = await vp.evaluate(() => window.SCENES);
  for (const id of ids) {
    await vp.evaluate((x) => window.show(x, "play"), id);
    await vp.waitForTimeout(DWELL[id] ?? SCENE_MS);
  }
  const webm = await vp.video().path();
  await vctx.close();
  const out = join(vidDir, `install-${lang}.mp4`);
  // Drop the blank first ~0.6 s (page load), H.264 + faststart so phones stream it.
  execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-ss", "0.6", "-i", webm, "-c:v", "libx264", "-preset", "slow", "-crf", "28",
    "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", out]);
  execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-ss", "1.5", "-i", out, "-frames:v", "1", "-quality", "80", join(vidDir, `install-${lang}-poster.webp`)]);
}
await browser.close();
rmSync(tmp, { recursive: true, force: true });
console.log(readdirSync(imgDir).length, "stills;", existsSync(join(vidDir, "install-en.mp4")) && existsSync(join(vidDir, "install-ar.mp4")) ? "2 videos" : "videos MISSING");
