# PR #983 Overview control screenshots

The OSRA Parent app renders the Overview screen from `31754c30f36a5f464aca208eb426861fd7c46fff` on an iPhone SE (3rd generation) simulator. The integration harness supplied a 320 logical px layout, 200% text scaling, and synthetic family and device state. The image crop removes the simulator status bar and its margins around the 320 px viewport.

Each frame shows Pause device, Resume device, and the current internet action. Arabic frames use the existing localization catalog and right-to-left layout. The test checked direction, theme, text scale, simultaneous visibility, hit testing, clipping, and layout exceptions. Each target measured 48 logical px high and 176.4–252.5 logical px wide. Visual inspection found complete labels on a single line in all eight frames.

| Internet state | English light | English dark | Arabic light | Arabic dark |
| --- | --- | --- | --- | --- |
| Regular | [PNG](regular/pr983-31754c30-en-light-regular.png) | [PNG](regular/pr983-31754c30-en-dark-regular.png) | [PNG](regular/pr983-31754c30-ar-light-regular.png) | [PNG](regular/pr983-31754c30-ar-dark-regular.png) |
| Paused | [PNG](paused/pr983-31754c30-en-light-paused.png) | [PNG](paused/pr983-31754c30-en-dark-paused.png) | [PNG](paused/pr983-31754c30-ar-light-paused.png) | [PNG](paused/pr983-31754c30-ar-dark-paused.png) |

[Test measurements](measurements.txt)
