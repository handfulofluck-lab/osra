// Line icons for the marketing pages: 24 x 24, one stroke, coloured by the text colour (currentColor), so they
// take the token colour of whatever holds them. Drawn for OSRA; no icon set is loaded from anywhere.
const svg = (body, cls = "icon") =>
  `<svg class="${cls}" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

export const icons = {
  clock: svg('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'),
  apps: svg('<rect x="4" y="4" width="6" height="6" rx="1.5"/><rect x="14" y="4" width="6" height="6" rx="1.5"/><rect x="4" y="14" width="6" height="6" rx="1.5"/><path d="M14 17h6M17 14v6"/>'),
  globe: svg('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/>'),
  bolt: svg('<path d="M13 3 5 13.5h6L10 21l8-10.5h-6z"/>'),
  pin: svg('<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>'),
  chat: svg('<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9.5h8M8 12.5h5"/>'),
  sos: svg('<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5"/><path d="m5.6 5.6 3.9 3.9M14.5 14.5l3.9 3.9M18.4 5.6l-3.9 3.9M9.5 14.5l-3.9 3.9"/>'),
  shield: svg('<path d="M12 3 5 6v5.5c0 4.4 3 8 7 9.5 4-1.5 7-5.1 7-9.5V6z"/><path d="m9 12 2 2 4-4"/>'),
  chart: svg('<path d="M4 20V4M4 20h16"/><path d="M8 16v-4M12 16V8M16 16v-6"/>'),
  family: svg('<circle cx="8.5" cy="7.5" r="3"/><circle cx="17" cy="10" r="2.3"/><path d="M3 20c0-3.2 2.5-5.5 5.5-5.5S14 16.8 14 20M14.5 20c.3-2.5 1.5-4 3.5-4s3 1.5 3 4"/>'),
  eu: svg('<circle cx="12" cy="12" r="9"/><path d="M12 6.5v.01M15.9 8.1v.01M17.5 12v.01M15.9 15.9v.01M12 17.5v.01M8.1 15.9v.01M6.5 12v.01M8.1 8.1v.01" stroke-width="2.4"/>'),
  noad: svg('<rect x="3" y="6" width="18" height="12" rx="2"/><path d="m4 4 16 16"/>'),
  lang: svg('<path d="M4 5h9M8.5 3v2M6 5c.5 3.5 2.5 6 6 7.5M11 5c-.6 3.6-2.8 6.6-7 8.5"/><path d="m13 21 4-9 4 9M14.4 18h5.2"/>'),
  eye: svg('<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>'),
  check: svg('<circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.7 2.7L16.5 9.5"/>'),
  android: svg('<path d="M6 10h12v7.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 17.5z"/><path d="M6 9a6 6 0 0 1 12 0zM8 4.5 9.2 6.5M16 4.5l-1.2 2M9.5 21v-2M14.5 21v-2"/>'),
  phone: svg('<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/>'),
  windows: svg('<path d="M3.5 5.5 10.5 4.5v7h-7zM13 4.2l7.5-1v8.3H13zM3.5 13h7v7l-7-1zM13 13h7.5v7.8L13 19.8z"/>'),
  laptop: svg('<rect x="5" y="5" width="14" height="10" rx="1.5"/><path d="M3 18.5h18"/>'),
  download: svg('<path d="M12 4v11M7.5 10.5 12 15l4.5-4.5M5 19.5h14"/>'),
  lock: svg('<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>'),
  mail: svg('<rect x="3" y="5.5" width="18" height="13" rx="2"/><path d="m4 7 8 6 8-6"/>'),
  book: svg('<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z"/><path d="M4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5"/>'),
  plus: svg('<path d="M12 5v14M5 12h14"/>'),
  bell: svg('<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/>'),
  // Social networks: plain glyphs, not the networks' logos.
  instagram: svg('<rect x="4" y="4" width="16" height="16" rx="4.5"/><circle cx="12" cy="12" r="3.6"/><path d="M16.8 7.2v.01" stroke-width="2.4"/>'),
  tiktok: svg('<path d="M14 4v10.5a3.5 3.5 0 1 1-3.5-3.5"/><path d="M14 4c.4 2.4 2 4 4.5 4.2"/>'),
  x: svg('<path d="m5 4 14 16M19 4 5 20"/>'),
  youtube: svg('<rect x="3" y="6" width="18" height="12" rx="3.5"/><path d="m10.5 9.5 4 2.5-4 2.5z"/>'),
  linkedin: svg('<rect x="4" y="4" width="16" height="16" rx="2.5"/><path d="M8 10.5V16M8 7.8v.01M11.5 16v-5.5M11.5 13c0-1.6 1-2.6 2.3-2.6s2.2.9 2.2 2.6V16"/>'),
  facebook: svg('<path d="M14.5 8H17V4.5h-2.5A3.5 3.5 0 0 0 11 8v2.5H8.5V14H11v6.5h3.5V14H17l.5-3.5h-3V8z"/>'),
};

// The Embrace mark, drawn large and in the tint behind the hero phone: ring = parent, dot = child. The geometry is
// MARK from scripts/brand/render.mjs, unchanged (BRAND.md: never redrawn); only the colours come from the sheet.
export const embrace = `<svg class="embrace" viewBox="0 0 100 100" aria-hidden="true"><path d="M76 50 A26 26 0 1 1 50 24" fill="none" stroke="currentColor" stroke-width="12" stroke-linecap="round"/><circle class="child" cx="68.4" cy="31.6" r="7.5" fill="currentColor"/></svg>`;
