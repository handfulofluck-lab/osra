# The pictures the Bureaus asked for on #727

Both Bureaus asked for the two coaching cards in Arabic, once with numbers and once without, and for one of the
numbers to contain a space. There are two kinds of picture here, and the difference matters.

## On the handset (Samsung Z Flip4, `R5CW116Y6GF`), Arabic, with numbers

| Card | File |
|---|---|
| Grooming | [handset_grooming_ar_numbers.png](handset_grooming_ar_numbers.png) |
| Self-harm | [handset_self_harm_ar_numbers.png](handset_self_harm_ar_numbers.png) |

Photographed with `adb screencap` from the real Flutter app on the real device, 1080 × 2640, One UI, Arabic UI. The
number in these pictures is the NSPCC line (`0808 800 5000`) and the UK emergency number (`999`), because the
handset's own country is GB — that is what a UK parent sees.

## Rendered from the widget, both languages, both cases

| Card | With numbers (device country `AE`) | Without numbers (unknown country) |
|---|---|---|
| Self-harm | [self_harm_ar_numbers.png](self_harm_ar_numbers.png) | [self_harm_ar_no_numbers.png](self_harm_ar_no_numbers.png) |
| Grooming | [grooming_ar_numbers.png](grooming_ar_numbers.png) | [grooming_ar_no_numbers.png](grooming_ar_no_numbers.png) |

`CoachCardSection` pumped inside the parent app's real localisation delegates at **360 dp**, locale `ar-AE` (numbers)
and `ar-ZZ` (no country row, so the sentence fallback), captured through a `RepaintBoundary` at 2×. Segoe UI and
Flutter's MaterialIcons are loaded, because a widget test otherwise draws every glyph as a box.

## Why the "no numbers" case is only a render

`deviceCountryCode()` reads the **platform** locale, not the app's. A `--dart-define` can force the app locale but not
the country the card resolves from, so the handset always printed the UK numbers. Producing a handset shot of the
no-number case would mean changing the box's **system** locale (to a country with no row) and restoring it — which is
exactly the state I do not want to leave on a phone another agent is about to use for a device pass. The render covers
the same code path: no row resolves, so the sentences appear.

## What they show, and why the Bureaus asked

- **The isolate holds, on the device and off it.** `0808 800 5000` is not reversed, and `116111` / `999` / `116 123`
  keep their order inside right-to-left sentences, with U+00A0 keeping a spaced number on one line.
- **The hours bracket sits after the line it belongs to**, in the Bureaus' own Arabic, including the Ramadan case:
  `(يعمل يوميًا من 08:00 إلى 20:00، وفي رمضان من 12:00 إلى منتصف الليل)`.
- **The no-number case is a sentence, never a placeholder**: «اتصل بخط الدعم النفسي في بلدك» and «فاتصل برقم الطوارئ في
  بلدك».
- **«فابقَ» without a comma** on the self-harm tip, and the grooming card's emergency sentence opening «أما إذا … ف».

## How the handset pictures were taken, honestly

A temporary entry point (`lib/main_card_shot.dart`) rendered the two cards with the app locale forced by
`--dart-define`, so the handset's system locale was never touched; the APK was installed under the app's own
application id, the tiles expanded by `adb input tap`, and the build **uninstalled** afterwards. The phone lease was
held for the run and released `Clean`. That file is not in this branch.
