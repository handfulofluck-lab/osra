String ltrIsolate(String value) => '\u{2066}$value\u{2069}';

/// First-strong directional isolate (Unicode FSI `U+2068` … PDI `U+2069`).
///
/// #1029 (UI/UX Bureau 7116862871, Arabic Language Bureau 7116877306): user-authored names
/// (e.g. a chat contact) may be Arabic, Latin, or mixed. FSI lets the contact's own first
/// strong character pick its run direction while isolating it from surrounding UI text.
String firstStrongIsolate(String value) => '\u{2068}$value\u{2069}';

/// A host name for display: left-to-right isolated, with a break opportunity after every dot.
///
/// #841 condition 2 (UI/UX Bureau): a host is the site's *name* on the history row, so it is drawn in
/// full — no ellipsis — and it must break at a dot before it breaks inside a word. A host name has no
/// spaces, so nothing in it is a natural break point; a zero-width space after each dot gives the line
/// breaker the point the reader expects, and renders as nothing. The isolate stays on the outside, so
/// the Arabic app shows the name left to right even though the sentence around it does not.
String ltrIsolateHost(String value) => ltrIsolate(value.replaceAll('.', '.\u{200B}'));

/// An email address for display: left-to-right isolated, with a break opportunity right after `@`.
///
/// PR #902 (Arabic Language Bureau): narrow 320 px / 200 % rows break inside `.com` unless given a
/// zero-width break after `@`. Keeping `ltrIsolate` around the address preserves Latin ordering in RTL.
String ltrIsolateEmail(String value) => ltrIsolate(value.replaceAll('@', '@\u{200B}'));
