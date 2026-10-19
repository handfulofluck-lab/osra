import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// Marker hue per device status.
double _statusHue(String status) => switch (status) {
      'online' => BitmapDescriptor.hueGreen,
      'locked' => BitmapDescriptor.hueOrange,
      'sos' => BitmapDescriptor.hueRed,
      _ => BitmapDescriptor.hueAzure,
    };

/// Family map: one marker per child (colored by status), geofence circles,
/// and a tap-through bottom sheet with Ring/Lock device commands. Live
/// updates arrive over [wsProvider]. A '+' app-bar button (or a map long-press)
/// opens the create-geofence dialog (#23).
class FamilyMapScreen extends ConsumerWidget {
  const FamilyMapScreen({super.key});

  /// Center for a new fence: the first child's latest ping, else 0,0 — a
  /// long-press on the map overrides this with the tapped point.
  LatLng _initialFenceCenter(WidgetRef ref, FamilyOverview overview) {
    for (final child in overview.children) {
      final ping = ref.read(locationProvider(child.id)).valueOrNull;
      if (ping != null) return LatLng(ping.lat, ping.lng);
    }
    return const LatLng(0, 0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(wsProvider); // keep the live channel subscribed while on this screen
    final family = ref.watch(familyProvider);
    final overview = family.valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family map'),
        actions: [
          IconButton(
            tooltip: 'Add geofence',
            icon: const Icon(Icons.add),
            onPressed: overview == null || overview.children.isEmpty
                ? null
                : () => showGeofenceCreateDialog(
                      context,
                      children: overview.children,
                      initialCenter: _initialFenceCenter(ref, overview),
                    ),
          ),
        ],
      ),
      body: family.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load family: $e')),
        data: (overview) => _MapBody(overview: overview),
      ),
    );
  }
}

/// Marker bottom sheet for one child: name, last update, coordinates, device
/// battery (feature #15) and Ring/Lock device commands.
class ChildMapSheet extends ConsumerWidget {
  final Child child;
  final LocationPing ping;
  final Device? device;
  const ChildMapSheet({super.key, required this.child, required this.ping, this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(child.displayName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpace.sm),
          Text('Last update: ${ping.timestamp == null ? 'unknown' : DateFormat.yMMMd().add_Hms().format(ping.timestamp!.toLocal())}'),
          const SizedBox(height: AppSpace.xs),
          // NOTE: reverse geocoding is a non-goal; show raw coordinates as the address placeholder.
          Text('${ping.lat.toStringAsFixed(6)}, ${ping.lng.toStringAsFixed(6)}'),
          if (device != null && device!.batteryPct > 0) ...[
            const SizedBox(height: AppSpace.xs),
            Text('Battery: ${device!.batteryPct}%'),
          ],
          const SizedBox(height: AppSpace.lg),
          Row(
            children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.volume_up),
                label: const Text('Ring device'),
                onPressed: device == null ? null : () => _sendCommand(context, ref, device!, 'ring'),
              ),
              const SizedBox(width: AppSpace.md),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.lock),
                label: const Text('Lock device'),
                onPressed: device == null ? null : () => _sendCommand(context, ref, device!, 'lock'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _sendCommand(BuildContext context, WidgetRef ref, Device device, String command) async {
    try {
      await ref.read(apiClientProvider).raw.post('/v1/devices/${device.id}/command', data: {'command': command});
      ref.invalidate(deviceCommandHistoryProvider(device.id));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${command[0].toUpperCase()}${command.substring(1)} queued for ${device.model} — the device has not confirmed it yet.'),
        ));
      }
    } on DioException catch (e) {
      if (context.mounted) {
        final data = e.response?.data;
        final msg = data is Map ? '${data['error'] ?? e.message}' : e.message;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Command failed: $msg')));
      }
    }
  }
}

class _MapBody extends ConsumerStatefulWidget {
  final FamilyOverview overview;
  const _MapBody({required this.overview});

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody> {
  GoogleMapController? _controller;

  /// Child marker positions from the last build; fed to [fitCameraToChildren].
  List<LatLng> _points = const [];

  /// The bounds fit runs once per screen visit (locations stream in async).
  bool _fitDone = false;

  /// Feature #21: fit the camera so every child marker is visible. Runs once,
  /// only when there is more than one child with a ping.
  void _maybeFit() {
    if (_fitDone || _points.length < 2) return;
    _fitDone = true;
    unawaited(fitCameraToChildren(_controller, _points));
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{};
    final circles = <Circle>{};
    final fenceColor = context.tokens.primary;
    LatLng? firstPing;
    final points = <LatLng>[];

    for (final child in widget.overview.children) {
      final ping = ref.watch(locationProvider(child.id)).valueOrNull;
      final device = widget.overview.devicesFor(child.id).firstOrNull;
      if (ping != null && firstPing == null) firstPing = LatLng(ping.lat, ping.lng);
      if (ping != null) {
        points.add(LatLng(ping.lat, ping.lng));
        markers.add(Marker(
          markerId: MarkerId(child.id),
          position: LatLng(ping.lat, ping.lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(_statusHue(device?.status ?? 'offline')),
          infoWindow: InfoWindow(title: child.displayName),
          onTap: () => _showChildSheet(context, ref, child, ping),
        ));
      }
      for (final fence in ref.watch(geofencesProvider(child.id)).valueOrNull ?? const <Geofence>[]) {
        circles.add(Circle(
          circleId: CircleId(fence.id),
          center: LatLng(fence.lat, fence.lng),
          radius: fence.radiusM,
          fillColor: fenceColor.withValues(alpha: 0.15),
          strokeColor: fenceColor,
          strokeWidth: 1,
        ));
      }
    }
    _points = points;
    _maybeFit();

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: firstPing ?? const LatLng(0, 0), zoom: firstPing == null ? 2 : 14),
          markers: markers,
          circles: circles,
          onMapCreated: (c) {
            _controller = c;
            _maybeFit();
          },
          // Feature #23: long-press drops a new geofence at the tapped point.
          onLongPress: widget.overview.children.isEmpty
              ? null
              : (latLng) => showGeofenceCreateDialog(
                    context,
                    children: widget.overview.children,
                    initialCenter: latLng,
                  ),
        ),
        if (widget.overview.children.isEmpty)
          const Center(child: Card(child: Padding(padding: EdgeInsets.all(AppSpace.lg), child: Text('No children to show')))),
      ],
    );
  }

  void _showChildSheet(BuildContext context, WidgetRef ref, Child child, LocationPing ping) {
    final device = widget.overview.devicesFor(child.id).firstOrNull;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ChildMapSheet(child: child, ping: ping, device: device),
    );
  }
}

/// Feature #21: fit the camera so all [points] are visible. No-ops without a
/// controller or with fewer than two points; animateCamera failures are
/// swallowed — NOTE: GoogleMap is unavailable in the widget-test environment,
/// so the controller may be missing or the platform view unready.
Future<void> fitCameraToChildren(GoogleMapController? controller, List<LatLng> points) async {
  if (controller == null || points.length < 2) return;
  try {
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final p in points) {
      south = math.min(south, p.latitude);
      north = math.max(north, p.latitude);
      west = math.min(west, p.longitude);
      east = math.max(east, p.longitude);
    }
    final bounds = LatLngBounds(southwest: LatLng(south, west), northeast: LatLng(north, east));
    await controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 48));
  } catch (_) {
    // NOTE: no-op — see doc comment.
  }
}

/// Opens the feature #23 create-geofence dialog for [children], centered on
/// [initialCenter] (the '+' button uses the first child's ping; a map
/// long-press uses the tapped point).
Future<void> showGeofenceCreateDialog(
  BuildContext context, {
  required List<Child> children,
  required LatLng initialCenter,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => GeofenceCreateDialog(children: children, initialCenter: initialCenter),
  );
}

/// Create-geofence dialog (feature #23): label, radius slider and an optional
/// 'Apply school routine when here' switch → `POST /v1/location/geofences`
/// with `routineId: 'school'` when the switch is on.
class GeofenceCreateDialog extends ConsumerStatefulWidget {
  final List<Child> children;
  final LatLng initialCenter;
  const GeofenceCreateDialog({super.key, required this.children, required this.initialCenter});

  @override
  ConsumerState<GeofenceCreateDialog> createState() => _GeofenceCreateDialogState();
}

class _GeofenceCreateDialogState extends ConsumerState<GeofenceCreateDialog> {
  final _label = TextEditingController();
  late String _childId = widget.children.first.id;
  double _radiusM = 250;
  bool _applySchoolRoutine = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final label = _label.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Enter a label');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).raw.post('/v1/location/geofences', data: {
        'childId': _childId,
        'label': label,
        'lat': widget.initialCenter.latitude,
        'lng': widget.initialCenter.longitude,
        'radiusM': _radiusM.round(),
        if (_applySchoolRoutine) 'routineId': 'school',
      });
      ref.invalidate(geofencesProvider(_childId));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Geofence "$label" added')));
    } on DioException catch (e) {
      if (!mounted) return;
      final body = e.response?.data;
      setState(() {
        _saving = false;
        _error = body is Map ? '${body['error'] ?? e.message}' : e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add geofence'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.children.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: DropdownButtonFormField<String>(
                  initialValue: _childId,
                  decoration: const InputDecoration(labelText: 'Child', border: OutlineInputBorder()),
                  items: [for (final c in widget.children) DropdownMenuItem(value: c.id, child: Text(c.displayName))],
                  onChanged: (v) => setState(() => _childId = v ?? widget.children.first.id),
                ),
              ),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label (e.g. School)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: AppSpace.md),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Radius: ${_radiusM.round()} m'),
            ),
            Slider(
              value: _radiusM,
              min: 100,
              max: 1000,
              divisions: 18,
              label: '${_radiusM.round()} m',
              onChanged: (v) => setState(() => _radiusM = v),
            ),
            SwitchListTile(
              title: const Text('Apply school routine when here'),
              subtitle: const Text('Agents enforce the school routine inside this fence'),
              value: _applySchoolRoutine,
              onChanged: (v) => setState(() => _applySchoolRoutine = v),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(_error!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.tokens.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _create,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ),
      ],
    );
  }
}
