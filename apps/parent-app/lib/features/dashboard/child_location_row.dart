import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/clock_provider.dart';
import '../../theme/app_tokens.dart';
import '../map/family_map_screen.dart';

const _placeLabelMaxAge = Duration(minutes: 15);
const _nearPlaceMeters = 100.0;

bool _validPosition(double lat, double lng) =>
    lat.isFinite && lng.isFinite && lat.abs() <= 90 && lng.abs() <= 180;

double _distanceMeters(
    double lat, double lng, double otherLat, double otherLng) {
  const toRadians = math.pi / 180;
  const earthRadius = 6371000;
  final sinLat = math.sin((otherLat - lat) * toRadians / 2);
  final sinLng = math.sin((otherLng - lng) * toRadians / 2);
  final a = sinLat * sinLat +
      math.cos(lat * toRadians) *
          math.cos(otherLat * toRadians) *
          sinLng *
          sinLng;
  return 2 * earthRadius * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
}

/// Use the reported accuracy circle to avoid saying "at" when the fix could
/// be outside a saved place. More specific contained places win on overlap.
({String name, bool at})? savedPlaceForFix(
  LocationPing fix,
  Iterable<Geofence> places,
  DateTime now,
) {
  final timestamp = fix.timestamp;
  if (timestamp == null || !_validPosition(fix.lat, fix.lng)) return null;
  final age = now.difference(timestamp);
  if (age.isNegative || age >= _placeLabelMaxAge) return null;
  if (!fix.accuracyM.isFinite || fix.accuracyM <= 0) return null;

  ({String name, bool at})? best;
  var bestRank = double.infinity;
  for (final place in places) {
    final name = place.label.trim();
    if (name.isEmpty ||
        !place.radiusM.isFinite ||
        place.radiusM <= 0 ||
        !_validPosition(place.lat, place.lng)) {
      continue;
    }
    final farEdge =
        _distanceMeters(fix.lat, fix.lng, place.lat, place.lng) + fix.accuracyM;
    final outside = farEdge - place.radiusM;
    if (outside > _nearPlaceMeters) continue;
    final at = outside <= 0;
    final rank = at ? place.radiusM : outside;
    if ((best?.at == true && !at) || (best?.at == at && rank >= bestRank))
      continue;
    best = (name: name, at: at);
    bestRank = rank;
  }
  return best;
}

class ChildLocationRow extends ConsumerStatefulWidget {
  const ChildLocationRow({
    super.key,
    required this.child,
    required this.fix,
    required this.places,
    required this.refused,
  });

  final Child child;
  final LocationPing? fix;
  final List<Geofence> places;
  final bool refused;

  @override
  ConsumerState<ChildLocationRow> createState() => _ChildLocationRowState();
}

class _ChildLocationRowState extends ConsumerState<ChildLocationRow> {
  Timer? _expiryTimer;
  DateTime? _scheduledExpiry;

  void _scheduleExpiry(DateTime? expiry, DateTime now) {
    if (expiry == _scheduledExpiry) return;
    _expiryTimer?.cancel();
    _scheduledExpiry = expiry;
    _expiryTimer = expiry == null
        ? null
        : Timer(expiry.difference(now), () {
            _scheduledExpiry = null;
            setState(() {});
          });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _openMap(BuildContext context, LocationPing location) async {
    final platform = Theme.of(context).platform;
    final childName = widget.child.displayName;
    if (!mapIsAvailable(platform)) {
      final uri = platformMapPinUri(
        platform,
        lat: location.lat,
        lng: location.lng,
        label: context.l10n.mapPreview,
      );
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } catch (_) {
        // The family map shows its existing unavailable state if there is no native handler.
      }
      if (!context.mounted) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FamilyMapScreen(
            focus: MapFocus.fromPing(location, label: childName)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final latest = widget.fix;
    final refused = widget.refused;
    final now = ref.watch(clockProvider)();
    final location =
        !refused && latest != null && _validPosition(latest.lat, latest.lng)
            ? latest
            : null;
    final place = location == null
        ? null
        : savedPlaceForFix(location, widget.places, now);
    _scheduleExpiry(
        place == null ? null : location?.timestamp?.add(_placeLabelMaxAge),
        now);
    final label = switch (place) {
      (name: final name, at: true) => l10n.childLocationAtPlace(name),
      (name: final name, at: false) => l10n.childLocationNearPlace(name),
      null => refused
          ? l10n.readPermissionRequired
          : location == null
              ? l10n.noLocationYet
              : l10n.alertShowOnMap,
    };
    final style = Theme.of(context).textTheme.bodySmall;
    final time = location?.timestamp;
    final contents = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.location_on_outlined, size: 14),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: style),
              if (time != null)
                Text(
                  l10n.familyMapLastUpdate(DateFormat.yMMMd(context.localeName)
                      .add_Hm()
                      .format(time.toLocal())),
                  style: style,
                ),
            ],
          ),
        ),
        if (location != null) const Icon(Icons.open_in_new, size: 16),
      ],
    );
    if (location == null) return contents;
    return Semantics(
      button: true,
      child: InkWell(
        key: ValueKey('child-location-map-${widget.child.id}'),
        onTap: () => _openMap(context, location),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(minHeight: kMinInteractiveDimension),
          child: contents,
        ),
      ),
    );
  }
}
