### Child agent — the block screen's window line in Arabic (#473, Q10)
- An Arabic phone now reads «محجوب بسبب وقت النوم حتى 07:00», «محجوب بسبب الساعات المدرسية حتى 15:00», or the family's own routine name, as typed. These are Karim's approved words (Q10, 31 Oct 15:30Z), the same ones the parent app already uses for bedtime and school hours.
- `ChildSystemStringsTest` pins the three lines as literals, and adds a row holding that both placeholders survive in order, so a translation that drops or swaps them turns red.
