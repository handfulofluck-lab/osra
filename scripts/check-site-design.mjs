#!/usr/bin/env node
/**
 * osratech.com wears the same design language as the apps (ADR-0038, roadmap 3.19). This keeps it there:
 *
 *   1. tokens: every `--name: #hex` in site/style.css equals `color.<name>` in docs/design/tokens.json, the light
 *      value in `:root` and the dark value inside `@media (prefers-color-scheme: dark)`; `--radius-<name>` equals
 *      `radius.<name>`. A token the stylesheet names that the file does not have is a finding.
 *   2. no colour anywhere else: a hex, rgb() or hsl() colour outside those two blocks, or in a page's `style`,
 *      is a finding (theme-color metas may carry the two page colours).
 *   3. nothing is fetched from a third party: a page or the stylesheet loads only same-site paths.
 *   4. direction: every page has `lang`; an Arabic page has `dir="rtl"`; the CSS uses no physical side
 *      (`left`/`right` in text-align, margin, padding, border or float), so one sheet serves both directions.
 *   5. type: the body font starts with the bundled IBM Plex Sans / IBM Plex Sans Arabic.
 *
 * Usage: node scripts/check-site-design.mjs [--selftest]
 * Exit 0: every rule holds. Exit 1: findings (each printed). Exit 2: site/style.css or tokens.json is missing.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const COLOUR = /#[0-9a-fA-F]{3,8}\b|\b(?:rgb|hsl)a?\(/;

/** The custom properties of `:root` in the sheet's top level (light) and in the dark media block. */
export function tokenBlocks(css) {
  const read = (block) => Object.fromEntries([...block.matchAll(/--([A-Za-z-]+)\s*:\s*([^;}]+)[;}]/g)].map((m) => [m[1], m[2].trim()]));
  const darkAt = css.search(/@media\s*\(prefers-color-scheme:\s*dark\)/);
  const first = css.match(/:root\s*\{([^}]*)\}/);
  const dark = darkAt < 0 ? null : css.slice(darkAt).match(/:root\s*\{([^}]*)\}/);
  return {
    light: first && (darkAt < 0 || first.index < darkAt) ? read(first[1]) : {},
    dark: dark ? read(dark[1]) : {},
    spans: [first && [first.index, first.index + first[0].length], dark && [darkAt + dark.index, darkAt + dark.index + dark[0].length]].filter(Boolean),
  };
}

export function checkCss(css, tokens) {
  const out = [];
  const blocks = tokenBlocks(css);
  for (const theme of ["light", "dark"]) {
    const vars = blocks[theme];
    if (Object.keys(vars).length === 0) out.push(`style.css: no ${theme} token block`);
    for (const [name, value] of Object.entries(vars)) {
      const radius = name.match(/^radius-(.+)$/);
      const want = radius ? tokens.radius?.[radius[1]]?.[theme] : tokens.color?.[name]?.[theme];
      if (want === undefined) { out.push(`style.css: --${name} (${theme}) is not a token in tokens.json`); continue; }
      const wanted = radius ? `${want}px` : String(want);
      if (value.toLowerCase() !== wanted.toLowerCase()) out.push(`style.css: --${name} (${theme}) is ${value}, tokens.json says ${wanted}`);
    }
  }
  for (const name of Object.keys(blocks.light)) if (!(name in blocks.dark)) out.push(`style.css: --${name} has no dark value`);
  // Rule 2: blank the two token blocks and the comments, then no colour may remain.
  let rest = css;
  for (const [from, to] of blocks.spans.sort((a, b) => b[0] - a[0])) rest = rest.slice(0, from) + " ".repeat(to - from) + rest.slice(to);
  rest = rest.replace(/\/\*[\s\S]*?\*\//g, (c) => " ".repeat(c.length));
  rest.split(/\r?\n/).forEach((line, i) => {
    if (COLOUR.test(line.replace(/U\+[0-9A-Fa-f-]+/g, ""))) out.push(`style.css:${i + 1}: a colour outside the token blocks`);
    if (/url\(\s*["']?(?:https?:)?\/\//.test(line) || /@import/.test(line)) out.push(`style.css:${i + 1}: loads from another site`);
    if (/(?:text-align|float|clear)\s*:\s*(?:left|right)\b|(?:margin|padding|border)-(?:left|right)\b|(?:^|[\s;{])(?:left|right)\s*:/.test(line)) out.push(`style.css:${i + 1}: a physical side (use start/end, inline-start/inline-end)`);
  });
  const body = rest.match(/(?:^|\})\s*body\s*\{([^}]*)\}/);
  if (!body || !/font[^;]*:\s*[^;]*"IBM Plex Sans(?: Arabic)?"\s*,\s*"IBM Plex Sans(?: Arabic)?"/.test(body[1])) out.push("style.css: body font does not start with IBM Plex Sans and IBM Plex Sans Arabic");
  return out;
}

export function checkHtml(name, html, pageColours = []) {
  const out = [];
  const tag = html.match(/<html\b[^>]*>/i)?.[0] ?? "";
  const lang = tag.match(/\blang="([^"]+)"/)?.[1];
  if (!lang) out.push(`${name}: <html> has no lang`);
  if (lang && /^ar\b/.test(lang) && !/\bdir="rtl"/.test(tag)) out.push(`${name}: an Arabic page without dir="rtl"`);
  for (const m of html.matchAll(/<(link|script|img|video|audio|source|iframe|object|embed)\b[^>]*?\b(?:src|href|poster|data)="((?:https?:)?\/\/[^"]*)"/gi)) out.push(`${name}: <${m[1]}> loads ${m[2]} from another site`);
  if (!/<link\b[^>]*href="\/style\.css"/.test(html)) out.push(`${name}: does not use /style.css`);
  const allowed = pageColours.map((c) => c.toLowerCase());
  const noMeta = html.replace(/<meta name="theme-color" content="(#[0-9A-Fa-f]{6})"[^>]*>/g, (m, c) => (allowed.includes(c.toLowerCase()) ? "" : m));
  for (const m of noMeta.matchAll(/<style\b[\s\S]*?<\/style>|\bstyle="[^"]*"|<meta name="theme-color"[^>]*>/gi)) {
    if (COLOUR.test(m[0])) out.push(`${name}: a colour in the page; colours come from the tokens in /style.css`);
    if (/text-align\s*:\s*(?:left|right)/.test(m[0])) out.push(`${name}: a physical side in the page's own style`);
  }
  return out;
}

function* walk(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, e.name);
    if (e.isDirectory()) yield* walk(full);
    else yield full;
  }
}

function runCli() {
  const cssPath = join(ROOT, "site/style.css");
  const tokensPath = join(ROOT, "docs/design/tokens.json");
  if (!existsSync(cssPath) || !existsSync(tokensPath)) {
    console.error(`missing ${existsSync(cssPath) ? "docs/design/tokens.json" : "site/style.css"}: the site cannot be compared with the design language`);
    return 2;
  }
  const tokens = JSON.parse(readFileSync(tokensPath, "utf8"));
  const findings = checkCss(readFileSync(cssPath, "utf8"), tokens);
  const pages = [...walk(join(ROOT, "site"))].filter((f) => f.endsWith(".html"));
  for (const page of pages) findings.push(...checkHtml(relative(ROOT, page), readFileSync(page, "utf8"), [tokens.color.page.light, tokens.color.page.dark]));
  if (findings.length === 0) {
    console.log(`site design: style.css and ${pages.length} page(s) match docs/design/tokens.json (ADR-0038)`);
    return 0;
  }
  for (const f of findings) console.error(f);
  console.error(`\n${findings.length} finding(s). The website uses the tokens of docs/design/tokens.json and nothing else; see docs/design/WEBSITE.md.`);
  return 1;
}

function selftest() {
  const tokens = { color: { page: { light: "#F1F5F4", dark: "#0E1417" }, ink: { light: "#12211F", dark: "#E9EFF1" }, cardBorder: { light: "transparent", dark: "#2B3840" } }, radius: { card: { light: 18, dark: 12 } } };
  const good = `:root { --page: #F1F5F4; --ink: #12211f; --cardBorder: transparent; --radius-card: 18px; }
@media (prefers-color-scheme: dark) { :root { --page: #0E1417; --ink: #E9EFF1; --cardBorder: #2B3840; --radius-card: 12px; } }
@font-face { font-family: "IBM Plex Sans"; src: url("/fonts/a.woff2"); unicode-range: U+0000-00FF, U+FEFF; }
body { background: var(--page); font: 400 16px/26px "IBM Plex Sans", "IBM Plex Sans Arabic", system-ui, sans-serif; }
th { text-align: start; padding-inline-start: 4px; }`;
  const page = (attrs, extra = "") => `<!doctype html><html ${attrs}><head><meta name="theme-color" content="#F1F5F4" media="(prefers-color-scheme: light)"><link rel="stylesheet" href="/style.css">${extra}</head><body></body></html>`;
  const colours = ["#F1F5F4", "#0E1417"];
  const cases = [
    ["the good sheet passes", () => checkCss(good, tokens), 0],
    ["a light value that drifted (the old indigo link)", () => checkCss(good.replace("--ink: #12211f", "--ink: #3949ab"), tokens), 1],
    ["a dark value that drifted", () => checkCss(good.replace("--page: #0E1417", "--page: #14151c"), tokens), 1],
    ["a radius that drifted", () => checkCss(good.replace("12px; } }", "18px; } }"), tokens), 1],
    ["a variable that is not a token", () => checkCss(good.replace("--radius-card: 18px;", "--radius-card: 18px; --link: #F1F5F4;"), tokens), 2],
    ["a colour written in a rule", () => checkCss(good + "\n.howto { background: #eef1ff; }", tokens), 1],
    ["a font fetched from another site", () => checkCss(good + '\n@font-face { font-family: X; src: url("https://fonts.example/x.woff2"); }', tokens), 1],
    ["a physical side", () => checkCss(good.replace("text-align: start", "text-align: left"), tokens), 1],
    ["a system font stack", () => checkCss(good.replace('"IBM Plex Sans", "IBM Plex Sans Arabic", ', ""), tokens), 1],
    ["no dark block", () => checkCss(good.split("\n").filter((l) => !l.startsWith("@media")).join("\n"), tokens).length > 0 ? ["x"] : [], 1],
    ["a good English page", () => checkHtml("p", page('lang="en"'), colours), 0],
    ["a good Arabic page", () => checkHtml("p", page('lang="ar" dir="rtl"'), colours), 0],
    ["an Arabic page without dir", () => checkHtml("p", page('lang="ar"'), colours), 1],
    ["a page without lang", () => checkHtml("p", page(""), colours), 1],
    ["a page with its own colour", () => checkHtml("p", page('lang="en"', "<style>h1 { color: #3949ab; }</style>"), colours), 1],
    ["a page that pins text to the right", () => checkHtml("p", page('lang="ar" dir="rtl"', "<style>th, td { text-align: right; }</style>"), colours), 1],
    ["a script from another site", () => checkHtml("p", page('lang="en"', '<script src="https://cdn.example/x.js"></script>'), colours), 1],
    ["a link to another site is not a load", () => checkHtml("p", page('lang="en"').replace("<body>", '<body><a href="https://play.google.com/">Play</a>'), colours), 0],
    ["a theme-color that is not the page colour", () => checkHtml("p", page('lang="en"').replace("#F1F5F4", "#ffffff"), colours), 1],
  ];
  // The cases above call the functions directly, so they pass even when the program does nothing as a
  // command. These two run it as a command: a wrong flag must exit 2 with a message, and a good tree must
  // print its summary line. (The workflow also asserts both summary lines, for the day this file is silent.)
  const self = fileURLToPath(import.meta.url);
  const asCommand = (...a) => spawnSync(process.execPath, [self, ...a], { encoding: "utf8" });
  cases.push(["the command rejects a flag it does not know", () => { const r = asCommand("--no-such-flag"); return r.status === 2 && /unrecognised argument/.test(r.stderr) ? [] : ["x"]; }, 0]);
  cases.push(["the command prints a summary or findings, never nothing", () => { const r = asCommand(); return (r.status === 0 && /^site design: /m.test(r.stdout)) || (r.status === 1 && /finding\(s\)/.test(r.stderr)) ? [] : ["x"]; }, 0]);
  let failed = 0;
  for (const [name, run, want] of cases) {
    const got = run().length;
    if (got !== want) { failed++; console.error(`SELFTEST FAIL: ${name}: ${got} finding(s), expected ${want}`); }
  }
  console.log(failed ? `${failed} of ${cases.length} self-test case(s) failed` : `site design self-test: ${cases.length} cases pass`);
  return failed ? 1 : 0;
}

const args = process.argv.slice(2);
// pathToFileURL, not a hand-built "file://" string: on Windows argv[1] is C:\…, which a template never
// turns into file:///C:/…, so the body below was skipped and the program exited 0 in silence (#592 review).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (args.some((a) => a !== "--selftest")) { console.error(`unrecognised argument: ${args.join(" ")}`); process.exit(2); }
  process.exit(args.includes("--selftest") ? selftest() : runCli());
}
