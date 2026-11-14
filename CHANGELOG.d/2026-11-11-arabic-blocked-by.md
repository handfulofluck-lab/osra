### Android child app — the Arabic block screen says «محجوب بواسطة» (Karim, 2026-11-11)
- The window line on the Android block screen now reads «محجوب بواسطة وقت النوم حتى 07:00»
  instead of «محجوب بسبب …», matching Karim's correction. The iPhone block screen already carries this
  wording on `main` (f7052b9b). `ChildSystemStringsTest` pins the resource itself; `BlockWindowCopyTest`
  pins the formatting and bidi isolates.
