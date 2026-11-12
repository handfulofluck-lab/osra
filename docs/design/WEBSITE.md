# osratech.com in the OSRA design language

**Decision:** ADR-0038 (one design language, two themes). **Roadmap:** 3.19. **Asked by the maintainer on
2026-11-12:** *"make sure … our website design is in line with our user experience and visual improvement …
one visual identity and branding."*

The website is one more surface of the design language, beside the apps. It uses the same tokens, the same type
family and the same component shapes, in English and Arabic.

## 1. What the site takes from the design language

| From `tokens.json` | On the site (`site/style.css`) |
|---|---|
| `color.*` | CSS variables with the token's own name (`--page`, `--card`, `--ink`, `--primary`, …). `:root` holds the Calm (light) values; `@media (prefers-color-scheme: dark)` holds the Control room (dark) values. |
| `radius.card`, `radius.control` | `--radius-card` (18 light, 12 dark), `--radius-control` (12 light, 8 dark). |
| `type.family` | IBM Plex Sans and IBM Plex Sans Arabic, weights 400, 600 and 700, served from `site/fonts/` (SIL Open Font License, `site/fonts/OFL.txt`). Nothing is fetched from a third party. |
| `type.scale` | `h1` is `screenTitle` (26/32, 700), `h2` is `pageTitle` (22/28, 700), `h3` is `cardTitle` (17/22, 700), small print is `secondary` (13/18). |
| `size.touchTargetMin`, `size.primaryButtonHeight` | Every link in the top bar and every row is at least 44 high. `.button` is 52 high. |

The page follows the reader's light or dark setting, as the apps do by default. There is no theme switch on the
site.

**One stated difference.** Body text is 16/26, one step above the app's 15/20 `body`, because the site's pages are
long legal text read in a browser. Nothing else departs from the tokens.

## 2. Page anatomy

Every page has the same three parts, in this order:

1. **Top bar** (`<header class="top">`): the wordmark, then the links Privacy, Delete account, Support. The current
   page's link is marked with `aria-current="page"`.
2. **One card** (`<main>`): the page's content on the `card` colour, on the `page` ground. In dark the card has
   the 1 px `cardBorder` outline.
3. **Footer**: the same links in the `muted` colour.

Components, each matching the app's:

| Class | Use | Matches |
|---|---|---|
| `.brand` | The logo, then the name: "OSRA" in Plex Sans 700 with «أسرة» in Plex Sans Arabic beside it | The app name and its Arabic name (`app_name`, `app_name_ar`) |
| `.rows` | A list of links, title at the start and a chevron at the end | Child page rows (design language 3.3) |
| `.button` | The one main action of a page | Primary button, 52 high |
| `.button.secondary` | A second action | Outlined secondary button |
| `.notice` | A line that needs attention | Needs-attention box (`warnContainer`) |
| `.meta` | Dates and small print | Secondary text |

The mark before the name is the OSRA logo the maintainer chose on 2026-11-12 ("Embrace", roadmap 3.20), as the
parent app's icon: `site/icon.svg`, which is also the favicon, and `site/apple-touch-icon.png`. Both are copies of
the brand masters; they are not redrawn for the site.

## 3. English and Arabic

- An Arabic page is `<html lang="ar" dir="rtl">` and uses the same stylesheet. The sheet names no physical side:
  it uses `text-align: start`, `padding-inline-start` and `margin-inline`, so the layout mirrors by itself.
- Arabic text renders in IBM Plex Sans Arabic; Latin words inside it (OSRA, an email address) in IBM Plex Sans.
- Arabic sentences are written whole and reviewed by the maintainer (design language 5), as in the apps.

## 4. Words

The site follows section 5 of the design language: durations as "12 months", buttons that name the action, and
sentences rather than data. Product names are written as the stores show them.

## 5. The check

`node scripts/check-site-design.mjs` (in `workflow-lint.yml`, with its `--selftest`) fails when:

- a variable in `site/style.css` differs from its token in `tokens.json`, in either theme, or is not a token;
- a colour is written anywhere outside the two token blocks, in the sheet or in a page;
- a page or the sheet loads anything from another site;
- a page has no `lang`, or an Arabic page has no `dir="rtl"`;
- the sheet names a physical side;
- the body font is not the bundled IBM Plex.

## 6. Acceptance

A page is done when it passes the check and has been looked at in a browser in both themes at 390 px and at
desktop width, in each language it is published in, with no horizontal scroll.
