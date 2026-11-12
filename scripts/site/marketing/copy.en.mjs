// English words of the marketing pages. Every product claim here is taken from text that is already true of the
// shipped code and reviewed: docs/store/play/store-listing-text.md (Play listing) and site/privacy/. Labels inside
// the drawn phone are the parent app's own strings (apps/parent-app/lib/l10n/app_en.arb). Change a claim here only
// when the product changes, and keep site/ar/ (copy.ar.mjs) in step through the Arabic Language Bureau.
export default {
  lang: "en",
  dir: "ltr",
  root: "/",
  other: { href: "/ar/", label: "العربية", lang: "ar" },
  beta: "mailto:support@osratech.com?subject=OSRA%20December%20beta",
  nav: { features: "Features", how: "How it works", guide: "Guide", download: "Download", join: "Join the beta", skip: "Skip to content", site: "Site" },

  title: "OSRA: family safety in Arabic and English",
  description: "Screen time, app limits, a web filter, location and chat safety alerts for your child, in Arabic and English. Visible to your child, stored in the EU, no ads.",

  hero: {
    kicker: "Closed beta · December 2026",
    h1: "Safer screens. Calmer homes.",
    lede: "OSRA brings screen time, app limits, a web filter, location and chat safety alerts together in one family app, in Arabic and English. It never hides from your child, and your family's data is stored in the EU.",
    primary: "Join the December beta",
    secondary: "See how it works",
    fine: "Android, iPhone and Windows in the closed beta. Mac in 2027.",
    mockLabel: "The OSRA parent app: each child on one card, with their phone's status, battery, internet switch, location and screen time today.",
  },
  // The drawn dashboard: the parent app's real child card (dashboard_screen.dart), in the app's own words.
  mock: {
    time: "9:41", app: "OSRA", online: "online", internet: "Internet", screenTime: "Screen time",
    kids: [
      { initials: "S", name: "Sara", battery: "86%", coords: "25.2048, 55.2708", value: "95 / 180 min" },
      { initials: "O", name: "Omar", battery: "41%", coords: "25.1972, 55.2744", value: "110 / 120 min" },
    ],
    add: "Add child",
    f1: { title: "Place alert", sub: "Places · Sara" },
    f2: { title: "Lock", sub: "Confirmed by device" },
  },

  proof: [
    { icon: "eu", title: "Stored in the EU", text: "Family data is kept in the European Union." },
    { icon: "noad", title: "No ads", text: "We do not sell data or use it for advertising." },
    { icon: "lang", title: "Arabic and English", text: "The parent and child apps speak both." },
    { icon: "eye", title: "Never hidden", text: "Your child always sees OSRA on their phone." },
  ],

  features: {
    kicker: "Everything in one app",
    h2: "Protection that fits real family life",
    lede: "Set the rules once from your phone. OSRA applies them on every device your child uses, and tells you when something needs you.",
    items: [
      { icon: "clock", title: "Screen time", text: "Daily and weekend limits, bedtime and school hours, and routines that allow or block apps at set times." },
      { icon: "apps", title: "App limits", text: "Block an app or give it its own daily limit. Your child can ask for access from the block screen." },
      { icon: "globe", title: "Web filter", text: "Block site categories and single sites, with SafeSearch and YouTube Restricted Mode. It runs on your child's phone." },
      { icon: "bolt", title: "Act right now", text: "Pause the internet or the phone, lock it, make it ring, or give bonus time, and see when the phone confirms it." },
      { icon: "pin", title: "Location and places", text: "See your child's phone on a map, ask for a fresh location, and get an alert when they arrive at or leave a place you saved." },
      { icon: "chat", title: "Chat safety alerts", text: "In the chat apps you choose, OSRA checks the text on screen for signs of self-harm, bullying or grooming, and alerts you.", note: "Checks use English phrases today. Arabic detection is in development." },
      { icon: "sos", title: "SOS button", text: "Your child can send you an SOS alert from a quick-settings tile, in one tap." },
      { icon: "shield", title: "Tamper alerts", text: "You are told if protection is switched off, and removing OSRA can be locked behind your parent PIN." },
    ],
  },

  how: {
    kicker: "Ready in minutes",
    h2: "How it works",
    lede: "Setting up one device takes about five minutes. Keep your child's phone next to you.",
    steps: [
      { title: "Install two apps", text: "OSRA on your phone. OSRA Kids on each phone or tablet your child uses." },
      { title: "Pair with a code", text: "Scan the QR code from your app with your child's phone, then tap Allow when your app asks." },
      { title: "Set the rules once", text: "Limits, bedtime, apps and web filter apply to every device of that child. Change them any time." },
    ],
    link: "Read the full guide",
  },

  ask: {
    kicker: "Choosing a family app?",
    h2: "Questions to ask any family app",
    lede: "Here is how OSRA answers each one.",
    rows: [
      { q: "Does it speak our language?", a: "Arabic and English, everywhere.", d: "The parent and child apps are in both languages, and Arabic reads right to left, as it should." },
      { q: "Where is our data kept?", a: "Stored in the European Union.", d: "Location history is deleted after 30 days. Message text that raises no concern is not stored." },
      { q: "Will my child know it is there?", a: "Yes. OSRA never hides.", d: "Your child sees the OSRA icon and a notification whenever it runs. We recommend telling them what it does and why." },
      { q: "Can I act at once, and know it worked?", a: "Lock, ring, pause or give bonus time in one tap.", d: "Each command shows when it reached the phone and when the phone confirmed it." },
      { q: "Does one plan cover every platform?", a: "That is our plan for launch.", d: "One family subscription, bought in the app, is planned to cover your child on Android, iPhone, Windows and, when it arrives, Mac." },
      { q: "Does it show ads or sell our data?", a: "No.", d: "OSRA shows no ads, and we do not sell data or share it for anyone else's purposes." },
    ],
  },

  platforms: {
    kicker: "Every screen at home",
    h2: "Every device, the same rules",
    lede: "Your child's phone, tablet and computer, under one set of rules. At launch, one family plan is planned to cover them all.",
    items: [
      { icon: "android", title: "Android", status: "In beta December", cls: "", lines: ["Parent app and OSRA Kids on Google Play", "Android 8.0 or later"] },
      { icon: "phone", title: "iPhone and iPad", status: "In beta December", cls: "", lines: ["Parent app and OSRA Kids on the App Store", "Built on Apple's Screen Time"] },
      { icon: "windows", title: "Windows", status: "In beta December", cls: "", lines: ["OSRA Kids for your child's PC", "Download from osratech.com"] },
      { icon: "laptop", title: "Mac", status: "2027", cls: "later", lines: ["OSRA Kids for your child's Mac", "Download from osratech.com"] },
    ],
    link: "See all downloads",
  },

  promise: {
    h2: "Built for trust between you and your child",
    lede: "Good protection works with your child, not behind their back. That is why OSRA is designed the way it is.",
    items: [
      "OSRA is always visible on your child's phone, and shows when it is active.",
      "You confirm you are the parent or guardian before adding a child, and you can withdraw consent at any time.",
      "Two-step verification protects your account. Invite a co-parent with their own login.",
      "Delete your account and your family's data from the app, or by email.",
    ],
    link: "Read our privacy policy",
  },

  faq: {
    h2: "Questions parents ask",
    items: [
      { q: "When can I get OSRA?", a: "A closed beta starts in December 2026 on Android, iPhone and Windows. Email us to join it. Public release follows, and Mac comes in 2027." },
      { q: "How much does it cost?", a: "Plans are announced at launch. You buy inside the app, through Google Play or the App Store, and one family plan is planned to cover your family on Android, iPhone, Windows and, when it arrives, Mac." },
      { q: "Will my child know OSRA is installed?", a: "Yes. OSRA shows its icon and a notification on your child's phone at all times. It is made for parents and legal guardians supervising their own children, and must not be installed on anyone else's phone." },
      { q: "Does OSRA read my child's messages?", a: "Only on-screen text in the chat apps you choose is checked for warning signs. Phone numbers and email addresses are masked on the phone before sending, and only flagged excerpts are kept, encrypted. The Google Play version does not read SMS, call logs or notifications." },
      { q: "Can two parents use it?", a: "Yes. The family owner invites a second parent or guardian, who manages the same children with their own login." },
      { q: "How do I delete my account?", a: "From the parent app, or by email. Everything is described on our delete account page." },
    ],
  },

  closing: { h2: "Be first to try OSRA", lede: "Join the closed beta in December. Tell us which phones your family uses, and we will send you an invitation.", primary: "Join the December beta", secondary: "Read the guide" },

  foot: {
    tagline: "Family safety in Arabic and English.",
    product: "Product", support: "Support", legal: "Legal", follow: "Follow OSRA",
    links: {
      features: "Features", how: "How it works", download: "Download", guide: "Guide",
      email: "support@osratech.com", del: "Delete your account", privacy: "Privacy policy", terms: "Terms of use",
    },
    copy: "© 2026 OSRA",
    notAffiliated: "OSRA is not affiliated with the apps it helps you supervise.",
  },

  download: {
    title: "Download OSRA",
    description: "Get the OSRA parent app and OSRA Kids for Android, iPhone, Windows and Mac.",
    kicker: "Closed beta · December 2026",
    h1: "Download OSRA",
    lede: "Two apps work together: OSRA on your phone, and OSRA Kids on each device your child uses. You pay inside the app, and at launch one family plan is planned to cover every device.",
    soon: "Coming with the beta",
    parent: { title: "OSRA", sub: "The parent app, for your phone", text: "Set rules, see where your child is, and get alerts." },
    kids: { title: "OSRA Kids", sub: "For each phone or tablet your child uses", text: "Applies your rules on the device, always visibly." },
    play: "Google Play", appstore: "App Store", getOn: "Get it on", downloadOn: "Download on the",
    computers: { h2: "Computers", lede: "OSRA Kids for your child's computer, downloaded from this site." },
    windows: { title: "OSRA Kids for Windows", status: "In beta December", text: "Your rules on your child's PC." },
    mac: { title: "OSRA Kids for Mac", status: "2027", text: "The same rules on your child's Mac, when it arrives." },
    full: {
      h2: "OSRA Kids Full for Android",
      status: "With the first release",
      text: "Google Play does not let any store app read SMS, the call log or other apps' notifications. OSRA Kids Full is the same child app with these extra protections, for parents who choose them. It will only ever come from osratech.com, with a step-by-step video and pictures for installing it.",
    },
    beta: { h2: "Want to be first?", lede: "Email us to join the December beta. Tell us which phones and computers your family uses.", button: "Join the December beta" },
    safe: { h2: "Only download OSRA from here", text: "Genuine OSRA apps come only from Google Play, the App Store and osratech.com. Never install OSRA from a link someone sends you." },
  },

  guide: {
    title: "OSRA guide",
    description: "How to set up OSRA: install the apps, pair your child's devices, set rules, and use location, alerts and SOS.",
    kicker: "Guide",
    h1: "The OSRA guide",
    lede: "Everything you need to set up OSRA and use it every day. Written for the December beta; some screens may still change a little.",
    contents: "Contents",
  },
  // /windows/ and /mac/ (ADR-0041 D4, roadmap 5.13). Built now, published only with the first working release
  // of each client (site-pages.yml leaves them out until then): no "coming soon", no price, no payment path.
  computer: {
    pairTitle: "Pair it with your child", installTitle: "Install it in three steps", needsTitle: "What it needs",
    doesTitle: "What it does", adminTitle: "Keep your child a Standard user",
    download: "The download button is added here with the first release.",
    free: "OSRA Kids for computers sells nothing. Your family plan is managed in the OSRA app on your phone.",
    windows: {
      title: "OSRA Kids for Windows",
      description: "Install OSRA Kids on your child's Windows PC and pair it with the OSRA app on your phone.",
      kicker: "Windows",
      h1: "OSRA Kids for Windows",
      lede: "The rules you set in the OSRA app, on your child's PC: the same limits, bedtime and web filter as on their phone.",
      does: [
        "Filters the web in every browser, with SafeSearch and YouTube Restricted Mode",
        "Blocks the apps you block, and applies screen time and bedtime with a lock screen",
        "Lets your child ask for more time, and send an SOS",
        "Tells you if OSRA is stopped or removed",
        "In Arabic and English",
      ],
      needs: ["Windows 10 (22H2) or Windows 11, on Intel, AMD or ARM", "An administrator account for you, and a Standard account for your child"],
      steps: [
        "Sign in to the PC with your administrator account and download OSRA Kids from this page.",
        "Open the installer and follow it. Windows may ask for your administrator password.",
        "When OSRA Kids opens, keep it on the pairing screen for the next step.",
      ],
      pair: [
        "On your phone, open your child in the OSRA app and tap Add a computer, then Windows.",
        "Type the six-digit code from your phone into OSRA Kids on the PC, then choose a parent PIN.",
        "Tap Allow on your phone when it asks. The PC now follows your child's rules.",
      ],
      admin: "If your child's Windows account is an administrator, they could remove OSRA, and the OSRA app warns you. Give your child a Standard account.",
    },
    mac: {
      title: "OSRA Kids for Mac",
      description: "Install OSRA Kids on your child's Mac and pair it with the OSRA app on your phone.",
      kicker: "Mac",
      h1: "OSRA Kids for Mac",
      lede: "The rules you set in the OSRA app, on your child's Mac, working alongside Apple's own parental controls.",
      does: [
        "Filters the web in every browser, with SafeSearch",
        "Blocks the apps you block, and applies screen time and bedtime with a lock screen",
        "Lets your child ask for more time",
        "Checks which of Apple's protections are on, and helps you turn on the rest",
        "Tells you if OSRA is stopped or removed",
        "In Arabic and English",
      ],
      needs: ["A Mac with a recent version of macOS", "An administrator account for you, and a Standard account for your child"],
      steps: [
        "Sign in to the Mac with your administrator account and download OSRA Kids from this page.",
        "Open the installer. macOS asks you to allow OSRA's background service and web filter; allow both.",
        "When OSRA Kids opens, keep it on the pairing screen for the next step.",
      ],
      pair: [
        "On your phone, open your child in the OSRA app and tap Add a computer, then Mac.",
        "Type the six-digit code from your phone into OSRA Kids on the Mac, then choose a parent PIN.",
        "Tap Allow on your phone when it asks. The Mac now follows your child's rules.",
      ],
      admin: "If your child's Mac account is an administrator, they could remove OSRA, and the OSRA app warns you. Give your child a Standard account.",
    },
  },
};
