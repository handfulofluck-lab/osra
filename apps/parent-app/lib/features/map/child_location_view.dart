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

/// The readable place for a fix, or null when the phone's geocoder has no answer (offline, rate
/// limited, open sea). Never throws: a failed lookup falls back to "address not available".
final placeNameProvider = FutureProvider.autoDispose.family<String?, PlaceQuery>((ref, q) async {
  ref.keepAlive();
  try {
    final marks = await ref.read(placemarkLookupProvider)(q.lat, q.lng, Locale(q.languageCode));
    if (marks.isEmpty) return null;
    return formatPlacemark(marks.first, separator: q.languageCode == 'ar' ? '، ' : ', ');
  } catch (_) {
    return null;
  }
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

/// One line for the child card: "Al Barsha, Dubai · updated 4 min ago".
class PlaceSummaryLine extends ConsumerWidget {
  final LocationPing ping;
  final TextStyle? style;
  const PlaceSummaryLine({super.key, required this.ping, this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider)();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        PlaceNameText(ping: ping, style: style, maxLines: 1),
        Text(
          locationFreshness(context, ping.timestamp, now),
          style: style?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
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
    final now = ref.watch(clockProvider)();
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
                Text(
                  [
                    locationFreshness(context, ping.timestamp, now),
                    if (accuracy != null) l10n.accuracyShort(accuracy),
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
class ChildLocationMap extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final point = ll.LatLng(ping.lat, ping.lng);
    return Semantics(
      label: context.l10n.locationMapSemantics(childName),
      child: FlutterMap(
        options: MapOptions(
          initialCenter: point,
          initialZoom: zoomFor(ping.accuracyM),
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag | InteractiveFlag.doubleTapZoom,
          ),
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
              child: Icon(Icons.location_on, size: 44, color: scheme.primary),
            ),
          ]),
          const SimpleAttributionWidget(source: Text('© OpenStreetMap contributors')),
        ],
      ),
    );
  }
}
