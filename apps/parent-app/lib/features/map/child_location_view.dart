import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/clock_provider.dart';
import '../../theme/app_tokens.dart';

/// Karim's 22 Nov test: the child card showed raw coordinates and the child profile showed a grey
/// "Map preview" box. A parent needs a place they recognise ("Al Barsha, Dubai"), how fresh it is
/// ("updated 4 min ago"), and a real map with the pin and its accuracy circle.
///
/// The place name comes from the phone's own reverse geocoder (Apple's on iOS, Google's on Android) —
/// no API key and nothing new on our servers. The map is OpenStreetMap tiles drawn by flutter_map, so it
/// works on the iPhone builds that have no Google Maps key compiled in (see `mapIsAvailable`).

/// One reverse-geocoding lookup. Coordinates are rounded to ~11 m so a phone reporting the same spot
/// with tiny jitter reuses the cached answer instead of asking the geocoder again.
@immutable
class PlaceQuery {
  final double lat;
  final double lng;
  final String languageCode;

  PlaceQuery(double lat, double lng, this.languageCode)
      : lat = (lat * 10000).roundToDouble() / 10000,
        lng = (lng * 10000).roundToDouble() / 10000;

  @override
  bool operator ==(Object other) =>
      other is PlaceQuery && other.lat == lat && other.lng == lng && other.languageCode == languageCode;

  @override
  int get hashCode => Object.hash(lat, lng, languageCode);
}

/// Test seam: widget tests replace the platform geocoder (there is none in the test environment).
typedef PlacemarkLookup = Future<List<Placemark>> Function(double lat, double lng, Locale locale);

final placemarkLookupProvider = Provider<PlacemarkLookup>(
  (ref) => (lat, lng, locale) => Geocoding(locale: locale).placemarkFromCoordinates(lat, lng),
);

/// A found place name is reused for this long, then looked up again (Codex on #1004: bounded cache).
const Duration kPlaceNameCacheFor = Duration(hours: 1);

/// A failed lookup is retried this often while the place line is on screen.
const Duration kPlaceNameRetryAfter = Duration(seconds: 30);

/// The readable place for a fix, or null when the phone's geocoder has no answer (offline, rate
/// limited, open sea). Never throws: a failed lookup falls back to "address not available".
///
/// Only a found name is cached, and only for [kPlaceNameCacheFor]. A failure is never cached: it is
/// retried every [kPlaceNameRetryAfter] while shown, and dropped as soon as nothing shows it, so a card
/// opened again after the phone is back online asks the geocoder afresh (Codex on #1004).
final placeNameProvider = FutureProvider.autoDispose.family<String?, PlaceQuery>((ref, q) async {
  String? name;
  try {
    final marks = await ref.read(placemarkLookupProvider)(q.lat, q.lng, Locale(q.languageCode));
    if (marks.isNotEmpty) name = formatPlacemark(marks.first, separator: q.languageCode == 'ar' ? '، ' : ', ');
  } catch (_) {
    name = null;
  }
  if (name != null) {
    final link = ref.keepAlive();
    final expiry = Timer(kPlaceNameCacheFor, link.close);
    ref.onDispose(expiry.cancel);
  } else {
    final retry = Timer(kPlaceNameRetryAfter, ref.invalidateSelf);
    ref.onDispose(retry.cancel);
  }
  return name;
});

/// "Street, Neighbourhood, City" with empty and repeated parts dropped, at most three parts.
String? formatPlacemark(Placemark p, {String separator = ', '}) {
  final parts = <String>[];
  for (final part in [p.thoroughfare, p.subLocality, p.locality ?? p.subAdministrativeArea, p.administrativeArea]) {
    final v = part?.trim() ?? '';
    if (v.isEmpty || parts.contains(v)) continue;
    parts.add(v);
    if (parts.length == 3) break;
  }
  if (parts.isEmpty) {
    final name = p.name?.trim() ?? '';
    return name.isEmpty ? null : name;
  }
  return parts.join(separator);
}

/// "Updated just now" / "Updated 4 min ago" / "Updated 2 hours ago" / "Updated 3 days ago".
String locationFreshness(BuildContext context, DateTime? timestamp, DateTime now) {
  final l10n = context.l10n;
  if (timestamp == null) return l10n.locationUpdatedUnknown;
  final age = now.difference(timestamp.toLocal());
  if (age.inMinutes < 1) return l10n.locationUpdatedJustNow;
  if (age.inMinutes < 60) return l10n.locationUpdatedMinutes(age.inMinutes);
  if (age.inHours < 24) return l10n.locationUpdatedHours(age.inHours);
  return l10n.locationUpdatedDays(age.inDays);
}

/// Bureau #1004: a fix older than this is flagged, so a parent does not read an old place as "now".
const Duration kStaleLocationAfter = Duration(minutes: 30);

bool isStaleFix(DateTime? timestamp, DateTime now) =>
    timestamp == null || now.difference(timestamp.toLocal()) > kStaleLocationAfter;

/// The freshness line: plain when recent; warning colour with a clock icon when stale (Bureau #1004).
class FreshnessLine extends ConsumerWidget {
  final DateTime? timestamp;
  final TextStyle? style;

  /// Text appended after the freshness (the accuracy on the profile card), kept in the same line.
  final String? suffix;
  const FreshnessLine({super.key, required this.timestamp, this.style, this.suffix});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider)();
    final stale = isStaleFix(timestamp, now);
    final theme = Theme.of(context);
    final color = stale ? context.tokens.severityWarningText : theme.colorScheme.onSurfaceVariant;
    final text = [locationFreshness(context, timestamp, now), if (suffix != null) suffix!].join(' · ');
    return Row(
      key: ValueKey(stale ? 'freshness-stale' : 'freshness-fresh'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stale) ...[
          Icon(Icons.schedule, size: (style?.fontSize ?? 14) + 2, color: color),
          const SizedBox(width: AppSpace.xs),
        ],
        Flexible(child: Text(text, style: style?.copyWith(color: color) ?? TextStyle(color: color))),
      ],
    );
  }
}

/// The place line for a fix: the place name once known, "Finding address…" while the lookup runs,
/// and "Address not available" when it fails. Never coordinates.
class PlaceNameText extends ConsumerWidget {
  final LocationPing ping;
  final TextStyle? style;
  final int maxLines;
  const PlaceNameText({super.key, required this.ping, this.style, this.maxLines = 2});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final lang = Localizations.localeOf(context).languageCode;
    final place = ref.watch(placeNameProvider(PlaceQuery(ping.lat, ping.lng, lang)));
    final text = place.when(
      data: (name) => name ?? l10n.locationAddressUnavailable,
      loading: () => l10n.locationFindingAddress,
      error: (_, __) => l10n.locationAddressUnavailable,
    );
    return Text(text, style: style, maxLines: maxLines, overflow: TextOverflow.ellipsis);
  }
}

/// The child card's place block: "Al Barsha, Dubai" over "Updated 4 min ago". Tapping it opens the child's
/// map (Bureau #1004), so the map is one tap from the dashboard even when the address is not available.
class PlaceSummaryLine extends StatelessWidget {
  final LocationPing ping;
  final TextStyle? style;
  final VoidCallback? onTap;
  const PlaceSummaryLine({super.key, required this.ping, this.style, this.onTap});

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        PlaceNameText(ping: ping, style: style, maxLines: 1),
        FreshnessLine(timestamp: ping.timestamp, style: style),
      ],
    );
    if (onTap == null) return body;
    return InkWell(
      key: const ValueKey('placeLine'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: body),
    );
  }
}

/// The child profile's location card: a real map with the pin and the accuracy circle, the place
/// name, freshness, accuracy, and an "Open in Maps" hand-off for directions.
class ChildLocationCard extends ConsumerWidget {
  final LocationPing ping;
  final String childName;
  const ChildLocationCard({super.key, required this.ping, required this.childName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final accuracy = ping.accuracyM > 0 ? ping.accuracyM.round() : null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(aspectRatio: 4 / 3, child: ChildLocationMap(ping: ping, childName: childName)),
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PlaceNameText(ping: ping, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpace.xs),
                FreshnessLine(
                  timestamp: ping.timestamp,
                  style: theme.textTheme.bodyMedium,
                  suffix: accuracy != null ? l10n.accuracyShort(accuracy) : null,
                ),
                const SizedBox(height: AppSpace.md),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    key: const ValueKey('openInMaps'),
                    icon: const Icon(Icons.directions_outlined, size: 18),
                    label: Text(l10n.alertOpenInMaps),
                    onPressed: () => openInMaps(ping, theme.platform),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Apple Maps on iOS, Google Maps elsewhere (both open the installed app when present, else the web).
Future<void> openInMaps(LocationPing ping, TargetPlatform platform) async {
  final q = '${ping.lat},${ping.lng}';
  final uri = platform == TargetPlatform.iOS
      ? Uri.parse('https://maps.apple.com/?ll=$q&q=$q')
      : Uri.parse('https://www.google.com/maps/search/?api=1&query=$q');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The map itself. Kept separate so widget tests can swap it out (tiles need the network).
///
/// It follows the child: a new fix recentres the map (Codex on #1004). Once the parent pans or zooms by
/// hand, following pauses and a recentre button appears; tapping it centres the latest fix and resumes.
class ChildLocationMap extends StatefulWidget {
  final LocationPing ping;
  final String childName;
  const ChildLocationMap({super.key, required this.ping, required this.childName});

  /// Zoom so the accuracy circle stays readable: street level for a precise fix, wider for a rough one.
  static double zoomFor(double accuracyM) {
    if (accuracyM <= 0 || accuracyM <= 50) return 16;
    if (accuracyM <= 200) return 15;
    if (accuracyM <= 1000) return 13.5;
    return 12;
  }

  @override
  State<ChildLocationMap> createState() => _ChildLocationMapState();
}

class _ChildLocationMapState extends State<ChildLocationMap> {
  final _controller = MapController();
  bool _ready = false;
  bool _following = true;

  LocationPing get ping => widget.ping;
  ll.LatLng get _point => ll.LatLng(ping.lat, ping.lng);

  @override
  void didUpdateWidget(ChildLocationMap old) {
    super.didUpdateWidget(old);
    final moved = old.ping.lat != ping.lat || old.ping.lng != ping.lng || old.ping.accuracyM != ping.accuracyM;
    if (moved && _following) _recentre();
  }

  void _recentre() {
    if (!_ready) return;
    _controller.move(_point, ChildLocationMap.zoomFor(ping.accuracyM));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final point = _point;
    return Semantics(
      label: l10n.locationMapSemantics(widget.childName),
      child: FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: point,
          initialZoom: ChildLocationMap.zoomFor(ping.accuracyM),
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag | InteractiveFlag.doubleTapZoom,
          ),
          onMapReady: () => _ready = true,
          onPositionChanged: (camera, hasGesture) {
            if (hasGesture && _following) setState(() => _following = false);
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.osratech.parent',
          ),
          if (ping.accuracyM > 0)
            CircleLayer(circles: [
              CircleMarker(
                point: point,
                radius: ping.accuracyM,
                useRadiusInMeter: true,
                color: scheme.primary.withValues(alpha: 0.15),
                borderColor: scheme.primary.withValues(alpha: 0.6),
                borderStrokeWidth: 1.5,
              ),
            ]),
          MarkerLayer(markers: [
            Marker(
              point: point,
              width: 44,
              height: 44,
              alignment: Alignment.topCenter,
              child: OutlinedPin(color: scheme.primary, size: 44),
            ),
          ]),
          const OsmAttribution(),
          if (!_following)
            Align(
              alignment: AlignmentDirectional.topEnd,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.sm),
                child: IconButton.filledTonal(
                  key: const ValueKey('recentreMap'),
                  tooltip: l10n.locationRecentre,
                  icon: const Icon(Icons.my_location),
                  onPressed: () {
                    setState(() => _following = true);
                    _recentre();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The OpenStreetMap credit line. flutter_map's SimpleAttributionWidget lays its text out in a Row that
/// cannot shrink, so it overflowed the map at 200% text (UI/UX on #1004). This one stays at 1x text
/// size, fits the map's width, and ellipsizes if the map is ever narrower than the line.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: MediaQuery.withNoTextScaling(
        child: ColoredBox(
          color: theme.colorScheme.surface.withValues(alpha: 0.85),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              '© OpenStreetMap contributors',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bureau #1004: the pin keeps a white outline, so it reads on light map tiles in the dark theme too.
class OutlinedPin extends StatelessWidget {
  final Color color;
  final double size;
  const OutlinedPin({super.key, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) => Icon(
        Icons.location_on,
        size: size,
        color: color,
        // A white halo traced by eight offset shadows: an outline that stays on the glyph's own shape.
        shadows: [
          for (final o in const [
            Offset(1.5, 0),
            Offset(-1.5, 0),
            Offset(0, 1.5),
            Offset(0, -1.5),
            Offset(1.1, 1.1),
            Offset(-1.1, 1.1),
            Offset(1.1, -1.1),
            Offset(-1.1, -1.1)
          ])
            Shadow(color: Colors.white, offset: o, blurRadius: 0.5),
        ],
      );
}
