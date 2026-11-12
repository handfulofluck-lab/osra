#!/usr/bin/env node
/**
 * Builds osratech.com's marketing pages (roadmap 3.21) from one template and two sets of words:
 *
 *   site/index.html            site/ar/index.html            home
 *   site/download/index.html   site/ar/download/index.html   downloads
 *   site/guide/index.html      site/ar/guide/index.html      the public guide
 *
 * and gives the legal pages (privacy, terms, delete-account) the same top bar and footer, leaving their text
 * untouched. Words live in copy.en.mjs / copy.ar.mjs and guide.en.html / guide.ar.html; style in site/style.css
 * (tokens only, checked by scripts/check-site-design.mjs). No script, tracker or third-party file on any page.
 *
 * Usage: node scripts/site/marketing/build.mjs [--check] [--preview-social]
 *   --check            write nothing; exit 1 if any page differs from what this script would write
 *   --preview-social   fill the social row with placeholder handles, for review screenshots only (never commit)
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { icons, embrace } from "./icons.mjs";
import en from "./copy.en.mjs";
import ar from "./copy.ar.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../../..");
const SITE = join(ROOT, "site");
const args = process.argv.slice(2);
const CHECK = args.includes("--check");
const PREVIEW_SOCIAL = args.includes("--preview-social");
for (const a of args) if (!["--check", "--preview-social"].includes(a)) { console.error(`unrecognised argument: ${a}`); process.exit(2); }

// OSRA's own social accounts. Empty until the maintainer creates them and gives the handles: an empty list
// renders no social row at all, so the live site never links to an account that does not exist.
const SOCIAL = PREVIEW_SOCIAL
  ? [
      { net: "instagram", name: "Instagram", href: "#social-placeholder" },
      { net: "tiktok", name: "TikTok", href: "#social-placeholder" },
      { net: "x", name: "X", href: "#social-placeholder" },
      { net: "youtube", name: "YouTube", href: "#social-placeholder" },
      { net: "linkedin", name: "LinkedIn", href: "#social-placeholder" },
    ]
  : [];

// The Arabic pages are built and reviewed, but published only after the Arabic Language Bureau signs them
// (site-pages.yml leaves site/ar/ out until then). While this is false, the English pages carry no link or
// hreflang to /ar/, so the live site never points at a page that is not there.
const ARABIC_PUBLISHED = false;
const showOther = (c) => c.lang === "ar" || ARABIC_PUBLISHED;

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const p = (c, path) => (c.lang === "ar" ? `/ar${path}` : path); // a marketing page in the reader's language

function head(c, { title, description, path, alt }) {
  return `<!doctype html>
<html lang="${c.lang}"${c.dir === "rtl" ? ' dir="rtl"' : ""}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#F1F5F4" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0E1417" media="(prefers-color-scheme: dark)">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:type" content="website">
<meta property="og:url" content="https://osratech.com${path}">
<meta property="og:image" content="https://osratech.com/apple-touch-icon.png">
<link rel="canonical" href="${path}">
<link rel="alternate" hreflang="${c.lang}" href="${path}">
${showOther(c) ? `<link rel="alternate" hreflang="${c.other.lang}" href="${alt}">\n` : ""}<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/style.css">
</head>
`;
}

function topbar(c, current, alt) {
  const link = (href, label, key) => `<a class="wide" href="${href}"${current === key ? ' aria-current="page"' : ""}>${esc(label)}</a>`;
  return `<a class="skip" href="#content">${esc(c.nav.skip)}</a>
<header class="top">
<a class="brand" href="${c.root}" aria-label="OSRA"><img src="/icon.svg" alt="" width="32" height="32">OSRA <span lang="ar" dir="rtl">أسرة</span></a>
<nav aria-label="${esc(c.nav.site)}">${link(`${c.root}#features`, c.nav.features)}${link(p(c, "/guide/"), c.nav.guide, "guide")}${link(p(c, "/download/"), c.nav.download, "download")}${showOther(c) ? `<a href="${alt}" hreflang="${c.other.lang}" lang="${c.other.lang}">${esc(c.other.label)}</a>` : ""}<a class="cta" href="${c.beta}">${esc(c.nav.join)}</a></nav>
</header>
`;
}

function footer(c) {
  const f = c.foot;
  const li = (href, label, extra = "") => `<li><a href="${href}"${extra}>${esc(label)}</a></li>`;
  const enOnly = c.lang === "ar" ? ' hreflang="en"' : "";
  const social = SOCIAL.length
    ? `<div class="social" aria-label="${esc(f.follow)}">${SOCIAL.map((s) => `<a href="${s.href}" aria-label="${esc(s.name)}" rel="me noopener">${icons[s.net]}</a>`).join("")}</div>`
    : "";
  return `<footer>
<div class="foot">
<div><a class="brand" href="${c.root}" aria-label="OSRA"><img src="/icon.svg" alt="" width="32" height="32">OSRA <span lang="ar" dir="rtl">أسرة</span></a><p>${esc(f.tagline)}</p>${social}</div>
<div><h4>${esc(f.product)}</h4><ul>${li(`${c.root}#features`, f.links.features)}${li(`${c.root}#how`, f.links.how)}${li(p(c, "/download/"), f.links.download)}${li(p(c, "/guide/"), f.links.guide)}</ul></div>
<div><h4>${esc(f.support)}</h4><ul>${li("mailto:support@osratech.com", f.links.email)}${li("/delete-account", f.links.del, enOnly)}</ul></div>
<div><h4>${esc(f.legal)}</h4><ul>${li("/privacy", f.links.privacy, enOnly)}${li("/terms", f.links.terms, enOnly)}</ul></div>
</div>
<div class="legal"><span dir="ltr">${esc(f.copy)} · osratech.com</span><span>${esc(f.notAffiliated)}</span></div>
</footer>
`;
}

function page(c, { key, path, alt, title, description, body }) {
  return `${head(c, { title, description, path, alt })}<body class="mk">
${topbar(c, key, alt)}<main id="content">
${body}</main>
${footer(c)}</body>
</html>
`;
}

// The parent app's dashboard, drawn: the same card, labels and order as dashboard_screen.dart (avatar and name;
// online, battery and Internet chips; location; screen time with its bar), then the Add child button.
function phone(c) {
  const m = c.mock;
  const card = (k, i) => `<div class="ccard"><div class="who"><span class="avatar${i ? " two" : ""}">${esc(k.initials)}</span>${esc(k.name)}</div>
<div class="chips"><span class="chip"><i></i>${esc(m.online)}</span><span class="chip">${esc(k.battery)}</span><span class="chip net">${esc(m.internet)}</span></div>
<div class="loc">${icons.pin.replace('class="icon"', 'class="icon" width="12" height="12" style="width:12px;height:12px"')}<span>${esc(k.coords)}</span></div>
<div class="st"><span>${esc(m.screenTime)}</span><span>${esc(k.value)}</span></div><div class="bar${i ? " b2" : ""}"><span></span></div></div>`;
  return `<div class="stage">${embrace}
<p class="sr">${esc(c.hero.mockLabel)}</p>
<div class="phone" aria-hidden="true"><div class="screen">
<div class="sbar"><span>${m.time}</span><span>5G ▮▮▮</span></div>
<div class="appbar"><span>${esc(m.app)}</span><span class="bell">${icons.bell.replace('class="icon"', 'class="icon" style="width:20px;height:20px"')}<b>3</b></span></div>
${m.kids.map(card).join("\n")}
<div class="fab"><span>${icons.plus.replace('class="icon"', 'class="icon" style="width:16px;height:16px"')}${esc(m.add)}</span></div>
</div></div>
<div class="float f1" aria-hidden="true"><span class="ic">${icons.pin}</span><span>${esc(m.f1.title)}<small>${esc(m.f1.sub)}</small></span></div>
<div class="float f2" aria-hidden="true"><span class="ic">${icons.check}</span><span>${esc(m.f2.title)}<small>${esc(m.f2.sub)}</small></span></div>
</div>`;
}

function home(c) {
  const h = c.hero;
  const body = `<section class="hero"><div class="wrap">
<div>
<p class="kicker"><span class="dot"></span>${esc(h.kicker)}</p>
<h1>${esc(h.h1)}</h1>
<p class="lede">${esc(h.lede)}</p>
<div class="actions"><a class="button" href="${c.beta}">${esc(h.primary)}</a><a class="button ghost" href="#how">${esc(h.secondary)}</a></div>
<p class="fine">${esc(h.fine)}</p>
</div>
${phone(c)}
</div></section>

<section class="band alt" aria-label="OSRA"><div class="wrap proof">
${c.proof.map((x) => `<div>${icons[x.icon]}<p><b>${esc(x.title)}</b><span>${esc(x.text)}</span></p></div>`).join("\n")}
</div></section>

<section class="band" id="features"><div class="wrap">
<div class="section-head"><p class="kicker">${esc(c.features.kicker)}</p><h2>${esc(c.features.h2)}</h2><p>${esc(c.features.lede)}</p></div>
<div class="grid">
${c.features.items.map((x) => `<article class="card"><span class="tile">${icons[x.icon]}</span><h3>${esc(x.title)}</h3><p>${esc(x.text)}</p>${x.note ? `<small class="note">${esc(x.note)}</small>` : ""}</article>`).join("\n")}
</div>
</div></section>

<section class="band alt" id="how"><div class="wrap">
<div class="section-head"><p class="kicker">${esc(c.how.kicker)}</p><h2>${esc(c.how.h2)}</h2><p>${esc(c.how.lede)}</p></div>
<ol class="steps">
${c.how.steps.map((s) => `<li><h3>${esc(s.title)}</h3><p>${esc(s.text)}</p></li>`).join("\n")}
</ol>
<p class="fine"><a href="${p(c, "/guide/")}">${esc(c.how.link)}</a></p>
</div></section>

<section class="band" id="why"><div class="wrap">
<div class="section-head"><p class="kicker">${esc(c.ask.kicker)}</p><h2>${esc(c.ask.h2)}</h2><p>${esc(c.ask.lede)}</p></div>
<ul class="ask">
${c.ask.rows.map((r) => `<li><span class="q">${esc(r.q)}</span><span class="a">${icons.check}<span><strong>${esc(r.a)}</strong>${esc(r.d)}</span></span></li>`).join("\n")}
</ul>
</div></section>

<section class="band alt" id="platforms"><div class="wrap">
<div class="section-head"><p class="kicker">${esc(c.platforms.kicker)}</p><h2>${esc(c.platforms.h2)}</h2><p>${esc(c.platforms.lede)}</p></div>
<div class="grid">
${c.platforms.items.map((x) => `<article class="card plat"><div class="head"><span class="tile">${icons[x.icon]}</span><h3>${esc(x.title)}</h3></div><span class="status${x.cls ? ` ${x.cls}` : ""}">${esc(x.status)}</span><ul>${x.lines.map((l) => `<li>${esc(l)}</li>`).join("")}</ul></article>`).join("\n")}
</div>
<p class="fine"><a href="${p(c, "/download/")}">${esc(c.platforms.link)}</a></p>
</div></section>

<section class="band promise" id="trust"><div class="wrap">
<div><h2>${esc(c.promise.h2)}</h2><p>${esc(c.promise.lede)}</p><p><a href="/privacy"${c.lang === "ar" ? ' hreflang="en"' : ""}>${esc(c.promise.link)}</a></p></div>
<ul>${c.promise.items.map((t) => `<li>${icons.check}<span>${esc(t)}</span></li>`).join("")}</ul>
</div></section>

<section class="band" id="faq"><div class="wrap">
<div class="section-head"><h2>${esc(c.faq.h2)}</h2></div>
<div class="faq">
${c.faq.items.map((x) => `<details><summary>${esc(x.q)}</summary><p>${esc(x.a)}</p></details>`).join("\n")}
</div>
</div></section>

<section class="band closing"><div class="wrap"><div class="card">
<img class="mark" src="/icon.svg" alt="" width="56" height="56">
<h2>${esc(c.closing.h2)}</h2>
<p class="lede">${esc(c.closing.lede)}</p>
<div class="actions"><a class="button" href="${c.beta}">${esc(c.closing.primary)}</a><a class="button ghost" href="${p(c, "/guide/")}">${esc(c.closing.secondary)}</a></div>
</div></div></section>
`;
  return page(c, { key: "home", path: c.root, alt: c.other.href, title: c.title, description: c.description, body });
}

function download(c) {
  const d = c.download;
  const store = (label, top) => `<span class="store" aria-disabled="true"><span><small>${esc(top)}</small>${esc(label)}</span></span>`;
  const app = (a, ic) => `<article class="card plat"><div class="head"><span class="tile">${icons[ic]}</span><div><h3>${esc(a.title)}</h3><p class="req">${esc(a.sub)}</p></div></div>
<p>${esc(a.text)}</p>
<span class="status">${esc(d.soon)}</span>
<div class="actions">${store(d.play, d.getOn)}${store(d.appstore, d.downloadOn)}</div></article>`;
  const comp = (a, ic, cls) => `<article class="card plat"><div class="head"><span class="tile">${icons[ic]}</span><h3>${esc(a.title)}</h3></div><span class="status${cls}">${esc(a.status)}</span><p>${esc(a.text)}</p></article>`;
  const body = `<section class="hero"><div class="wrap" style="grid-template-columns: 1fr">
<div>
<p class="kicker"><span class="dot"></span>${esc(d.kicker)}</p>
<h1>${esc(d.h1)}</h1>
<p class="lede">${esc(d.lede)}</p>
</div>
</div></section>

<section class="band alt"><div class="wrap">
<div class="dl">
${app(d.parent, "family")}
${app(d.kids, "phone")}
</div>
</div></section>

<section class="band"><div class="wrap">
<div class="section-head"><h2>${esc(d.computers.h2)}</h2><p>${esc(d.computers.lede)}</p></div>
<div class="dl">
${comp(d.windows, "windows", "")}
${comp(d.mac, "laptop", " later")}
</div>
</div></section>

<section class="band alt"><div class="wrap">
<article class="card plat"><div class="head"><span class="tile">${icons.android}</span><h2 style="font-size: 22px; line-height: 28px; margin: 0">${esc(d.full.h2)}</h2></div>
<span class="status gated">${icons.lock.replace('class="icon"', 'class="icon" style="width:14px;height:14px"')}${esc(d.full.status)}</span>
<p>${esc(d.full.text)}</p></article>
</div></section>

<section class="band"><div class="wrap grid two">
<article class="card"><span class="tile">${icons.mail}</span><h3>${esc(d.beta.h2)}</h3><p>${esc(d.beta.lede)}</p><p style="margin-top: 16px"><a class="button" href="${c.beta}">${esc(d.beta.button)}</a></p></article>
<article class="card"><span class="tile">${icons.shield}</span><h3>${esc(d.safe.h2)}</h3><p>${esc(d.safe.text)}</p></article>
</div></section>
`;
  return page(c, { key: "download", path: p(c, "/download/"), alt: c.lang === "ar" ? "/download/" : "/ar/download/", title: d.title, description: d.description, body });
}

function guide(c, html) {
  const g = c.guide;
  const content = html.replace(/<!--[\s\S]*?-->\s*/, "");
  const toc = [...content.matchAll(/<h2 id="([^"]+)">([^<]+)<\/h2>/g)].map((m) => `<li><a href="#${m[1]}">${m[2]}</a></li>`).join("");
  const body = `<section class="hero"><div class="wrap" style="grid-template-columns: 1fr">
<div>
<p class="kicker">${icons.book.replace('class="icon"', 'class="icon" style="width:16px;height:16px"')}${esc(g.kicker)}</p>
<h1>${esc(g.h1)}</h1>
<p class="lede">${esc(g.lede)}</p>
</div>
</div></section>
<section class="band" style="padding-top: 0"><div class="wrap guide">
<nav class="toc" aria-label="${esc(g.contents)}"><ol>${toc}</ol></nav>
<article class="doc">
${content.trim()}
</article>
</div></section>
`;
  return page(c, { key: "guide", path: p(c, "/guide/"), alt: c.lang === "ar" ? "/guide/" : "/ar/guide/", title: g.title, description: g.description, body });
}

// The legal pages keep their own text (reviewed and approved as it is); only the top bar and footer change.
function legal(file, html) {
  const top = `<header class="top">
<a class="brand" href="/" aria-label="OSRA"><img src="/icon.svg" alt="" width="32" height="32">OSRA <span lang="ar" dir="rtl">أسرة</span></a>
<nav aria-label="Site"><a href="/#features">Features</a><a href="/guide/">Guide</a><a href="/download/">Download</a><a href="mailto:support@osratech.com">Support</a></nav>
</header>`;
  const foot = `<footer>OSRA · <a href="/">osratech.com</a> · <a href="/guide/">Guide</a> · <a href="/download/">Download</a> · <a href="/privacy">Privacy policy</a> · <a href="/terms">Terms of use</a> · <a href="/delete-account">Delete your account</a> · <a href="mailto:support@osratech.com">support@osratech.com</a></footer>`;
  const out = html.replace(/<header class="top">[\s\S]*?<\/header>/, top).replace(/<footer>[\s\S]*?<\/footer>/, foot);
  if (out === html && !html.includes(top)) throw new Error(`${file}: no top bar or footer to replace`);
  return out;
}

const pages = {
  "index.html": home(en),
  "ar/index.html": home(ar),
  "download/index.html": download(en),
  "ar/download/index.html": download(ar),
  "guide/index.html": guide(en, readFileSync(join(HERE, "guide.en.html"), "utf8")),
  "ar/guide/index.html": guide(ar, readFileSync(join(HERE, "guide.ar.html"), "utf8")),
};
for (const f of ["privacy/index.html", "terms/index.html", "delete-account/index.html"]) pages[f] = legal(f, readFileSync(join(SITE, f), "utf8"));

let differ = 0;
for (const [rel, html] of Object.entries(pages)) {
  const file = join(SITE, rel);
  const now = existsSync(file) ? readFileSync(file, "utf8") : null;
  if (now === html) continue;
  if (CHECK) { differ++; console.error(`site/${rel} differs from what scripts/site/marketing/build.mjs writes`); continue; }
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, html);
  console.log(`wrote site/${rel}`);
}
if (CHECK) {
  if (differ) { console.error(`\n${differ} page(s) out of date: run node scripts/site/marketing/build.mjs`); process.exit(1); }
  console.log(`marketing pages: ${Object.keys(pages).length} page(s) match their sources`);
}
