### Android child — a routine can no longer block the phone's own setup and permission screens (#1096)
- Found on Ahmed's Redmi (MIUI) child-2 run: pairing after 21:00 let the default Bedtime cover Xiaomi's Security app, which hosts the Autostart and permission screens OSRA asks the child to open.
- The block overlay now leaves the permission controller, the package installer and the OEM security centres (Xiaomi, Samsung device care, OPPO/OnePlus, vivo, Huawei/Honor, Transsion) alone, but only when the OS reports them as system apps. A sideloaded app with the same name stays blockable.
- The lock is unchanged: it still covers these screens.
