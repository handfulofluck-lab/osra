#!/usr/bin/env node
/**
 * Fails when a computer download page offers a way to pay (ADR-0041 claim 8).
 *
 * ADR-0041 D4: the Windows and Mac pages only offer downloads. The family plan is bought in the OSRA app on
 * the parent's phone, through Google Play or the App Store, so a buy button here would bill a family twice
 * and would put every download link in front of the store rules on steering. The rule: no page under
 * site/windows/, site/mac/ (and their Arabic twins under site/ar/) contains a price, the words "buy",
 * "subscribe", "checkout", "pricing", or their Arabic equivalents, or a link to a payment host.
 *
 * Usage:
 *   node scripts/check-site-no-payment.mjs              # scan the computer pages
 *   node scripts/check-site-no-payment.mjs --selftest   # prove each rule fires and plain copy passes
 *
 * Exits 1 on a finding, 2 when there is nothing to scan.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIRS = ['site/windows', 'site/ar/windows', 'site/mac', 'site/ar/mac'];

/** Each rule: a name and a test on the page text (tags kept, so links count too). */
const RULES = [
  ['a price', /(?:[$€£]\s?\d|\d\s?(?:USD|EUR|GBP|AED|SAR|ر\.س|د\.إ|درهم|ريال|دولار|يورو)\b|\b(?:USD|EUR|GBP|AED|SAR)\s?\d)/i],
  ['the word buy', /\bbuy(?:ing|s)?\b/i],
  ['the word subscribe', /\bsubscri(?:be|bes|bing|ption)\b/i],
  ['the word checkout', /\bcheck-?out\b/i],
  ['the word pricing', /\bpric(?:e|es|ing)\b/i],
  ['an Arabic word to pay', /(?:اشتر(?:ِ|ك|اك)|شراء|ادفع|الدفع|سعر|الأسعار|أسعار)/],
  ['a link to a payment host', /href\s*=\s*["'][^"']*(?:stripe\.com|paypal\.|checkout\.|paddle\.|lemonsqueezy|gumroad|fastspring|\/pay(?:ment)?\b|\/buy\b|\/checkout\b|\/pricing\b)/i],
];

export function findings(text) {
  return RULES.filter(([, re]) => re.test(text)).map(([name]) => name);
}

function pages() {
  const out = [];
  for (const d of DIRS) {
    const abs = path.join(ROOT, d);
    if (!fs.existsSync(abs)) continue;
    for (const f of fs.readdirSync(abs, { recursive: true })) {
      if (String(f).endsWith('.html')) out.push(path.join(d, String(f)));
    }
  }
  return out;
}

function selftest() {
  const cases = [
    ['plain copy passes', '<p>Install OSRA Kids on the child\'s computer. Your family plan is managed in the OSRA app.</p>', []],
    ['Arabic plain copy passes', '<p>تُدار خطة العائلة من تطبيق أسرة على هاتفك.</p>', []],
    ['dollar price', '<p>Only $4.99 a month</p>', ['a price']],
    ['AED price', '<p>19 AED</p>', ['a price']],
    ['buy button', '<a class="btn">Buy now</a>', ['the word buy']],
    ['subscribe', '<p>Subscribe today</p>', ['the word subscribe']],
    ['checkout', '<p>Go to checkout</p>', ['the word checkout']],
    ['pricing', '<a>See pricing</a>', ['the word pricing']],
    ['Arabic buy', '<a>اشترك الآن</a>', ['an Arabic word to pay']],
    ['Arabic price', '<p>السعر</p>', ['an Arabic word to pay']],
    ['stripe link', '<a href="https://buy.stripe.com/x">Go</a>', ['a link to a payment host']],
    ['pay path', '<a href="/pay">Go</a>', ['a link to a payment host']],
  ];
  let bad = 0;
  for (const [name, text, want] of cases) {
    const got = findings(text);
    const ok = want.every((w) => got.includes(w)) && (want.length > 0 || got.length === 0);
    if (!ok) { bad++; console.error(`FAIL ${name}: wanted ${JSON.stringify(want)}, got ${JSON.stringify(got)}`); }
  }
  if (bad) process.exit(1);
  console.log(`site no-payment self-test: ${cases.length} cases pass`);
}

if (process.argv.includes('--selftest')) {
  selftest();
} else {
  const list = pages();
  if (list.length === 0) { console.error('site no-payment: no computer pages found under ' + DIRS.join(', ')); process.exit(2); }
  let bad = 0;
  for (const p of list) {
    const hits = findings(fs.readFileSync(path.join(ROOT, p), 'utf8'));
    for (const h of hits) { bad++; console.error(`${p}: contains ${h} (ADR-0041 claim 8: computer pages offer downloads only)`); }
  }
  if (bad) process.exit(1);
  console.log(`site no-payment: ${list.length} computer page(s) offer no way to pay`);
}
