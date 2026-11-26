import 'dart:async' show unawaited;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import '../children/command_messages.dart';
import 'child_location_view.dart';
import 'family_map_screen.dart'
    show fitCameraToChildren, mapIsAvailable, showGeofenceCreateDialog;

/// Feature switch for UX Final Decisions P-13 Location (#1179).
///
/// Enable via `--dart-define=OSRA_UX_P13=true` or override
/// [p13LocationEnabledProvider] in tests. When `false`, `FamilyMapScreen`
/// falls back to the legacy map view.
const bool kEnableUxP13Location = bool.fromEnvironment(
  'OSRA_UX_P13',
  defaultValue: false,
);

final p13LocationEnabledProvider = Provider<bool>(
  (ref) => kEnableUxP13Location,
);

/// UX Final Decisions **P-13 Location** (#1179, G18, A2, A7, A8):
/// - Real map with child pin(s) and accuracy ring (in `All` mode, shows every
///   child's pin on the family map; no `"Live"` badge, no route drawn on the
///   card, never raw coordinates).
/// - Child selector chips (`All` + each child).
/// - Place card in words (`PlaceNameText` + `FreshnessLine` + accuracy +
///   battery), with **Refresh** (awaits refreshed reads while keeping the old
///   pin visible), **Directions**, and **Ring** (flips to **Stop ringing**
///   while ringing on Android, A2; shows "Not yet available on iPhone" on iOS, G6).
/// - **"Earlier today"** row (A7) opening today's places in a bottom sheet.
/// - **Saved places** list with radius + enter/leave alert state and **"Add
///   place"** (A8, keeping radius and both alert switches).
class LocationP13Screen extends ConsumerStatefulWidget {
  final String? initialChildId;
  const LocationP13Screen({super.key, this.initialChildId});

  @override
  ConsumerState<LocationP13Screen> createState() => _LocationP13ScreenState();
}

class _LocationP13ScreenState extends ConsumerState<LocationP13Screen> {
  /// Null means "All" children mode when >1 child; otherwise the selected childId.
  String? _selectedChildId;
  bool _refreshing = false;
  bool _ringSent = false;
  bool _sendingCommand = false;

  @override
  void initState() {
    super.initState();
    _selectedChildId = widget.initialChildId;
  }

  Child? _resolveFocusedChild(List<Child> children) {
    if (children.isEmpty) return null;
    if (_selectedChildId != null) {
      final hit = children.where((c) => c.id == _selectedChildId).firstOrNull;
      if (hit != null) return hit;
    }
    return children.first;
  }

  Future<void> _refreshLocation(Child child, Device? device) async {
    if (_refreshing) return;
    final l10n = context.l10n;
    setState(() => _refreshing = true);
    try {
      if (device != null) {
        try {
          final response = await ref.read(apiClientProvider).raw.post(
            '/v1/devices/${device.id}/command',
            data: {'command': 'locate_now'},
          );
          final body = response.data;
          if (mounted && body is Map && body['status'] == 'failed') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  commandRefusalText(l10n, 'locate_now', device.model, body['reason']),
                ),
              ),
            );
          }
        } on DioException catch (e) {
          if (mounted) {
            showErrorSnackBar(
              context,
              commandErrorText(l10n, 'locate_now', device.model, e),
              onRetry: () => _refreshLocation(child, device),
            );
          }
        }
      }
      await Future.wait([
        ref.refresh(locationProvider(child.id).future).then<void>((_) {}).catchError((_) {}),
        ref.refresh(locationHistoryProvider(child.id).future).then<void>((_) {}).catchError((_) {}),
        ref.refresh(familyProvider.future).then<void>((_) {}).catchError((_) {}),
      ]);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _toggleRing(Device device) async {
    if (_sendingCommand) return;
    if (device.platform.toLowerCase() == 'ios') return;
    final l10n = context.l10n;
    final cmd = _ringSent ? 'stop_ring' : 'ring';
    setState(() => _sendingCommand = true);
    try {
      final response = await ref.read(apiClientProvider).raw.post(
        '/v1/devices/${device.id}/command',
        data: {'command': cmd},
      );
      ref.invalidate(deviceCommandHistoryProvider(device.id));
      if (!mounted) return;
      final body = response.data;
      if (body is Map && body['status'] == 'failed') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              commandRefusalText(l10n, cmd, device.model, body['reason']),
            ),
          ),
        );
        return;
      }
      setState(() => _ringSent = cmd == 'ring');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.commandQueued(
              cmd == 'ring' ? l10n.commandRing : l10n.commandStopRing,
              ltrIsolate(device.model),
            ),
          ),
        ),
      );
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(commandErrorText(l10n, cmd, device.model, e))),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingCommand = false);
    }
  }

  Future<void> _openEarlierTodaySheet(Child child) async {
    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _EarlierTodaySheet(child: child, title: l10n.locationP13EarlierToday),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(wsProvider);
    final l10n = context.l10n;
    final tokens = context.tokens;
    final family = ref.watch(familyProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabLocation),
      ),
      body: family.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.familyLoadFailed),
          onRetry: () => ref.invalidate(familyProvider),
        ),
        data: (overview) {
          final children = overview.children;
          if (children.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Text(
                  l10n.locationP13NoLocationYet,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: tokens.onSurfaceVariant,
                      ),
                ),
              ),
            );
          }

          final showAllMode = _selectedChildId == null && children.length > 1;
          final focusedChild = _resolveFocusedChild(children)!;
          final devices = overview.devicesFor(focusedChild.id);
          final primaryDevice = devices.isNotEmpty ? devices.first : null;
          final isIosDevice = primaryDevice?.platform.toLowerCase() == 'ios';
          final locationAsync = ref.watch(locationProvider(focusedChild.id));
          final geofencesAsync = ref.watch(geofencesProvider(focusedChild.id));
          final ping = locationAsync.valueOrNull;
          final geofences = geofencesAsync.valueOrNull ?? const <Geofence>[];
          final accuracy = ping != null && ping.accuracyM > 0 ? ping.accuracyM.round() : null;

          final allPins = <({Child child, LocationPing ping, Device? device})>[];
          if (showAllMode) {
            for (final c in children) {
              final p = ref.watch(locationProvider(c.id)).valueOrNull;
              if (p != null) {
                allPins.add((child: c, ping: p, device: overview.devicesFor(c.id).firstOrNull));
              }
            }
          }

          return RefreshIndicator(
            onRefresh: () => _refreshLocation(focusedChild, primaryDevice),
            child: SingleChildScrollView(
              key: const ValueKey('p13ScrollView'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                AppSpace.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (children.length > 1) ...[
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            key: const ValueKey('p13Chip-all'),
                            label: Text(l10n.locationP13AllChildren),
                            selected: showAllMode,
                            onSelected: (_) => setState(() {
                              _selectedChildId = null;
                              _ringSent = false;
                            }),
                          ),
                          for (final c in children) ...[
                            const SizedBox(width: AppSpace.sm),
                            ChoiceChip(
                              key: ValueKey('p13Chip-${c.id}'),
                              label: Text(firstStrongIsolate(c.displayName)),
                              selected: _selectedChildId == c.id,
                              onSelected: (_) => setState(() {
                                _selectedChildId = c.id;
                                _ringSent = false;
                              }),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                  ],
                  // Map with accuracy ring (old pin stays visible while Refresh is running;
                  // All mode renders every child's pin on the family map)
                  Card(
                    key: const ValueKey('p13MapCard'),
                    clipBehavior: Clip.antiAlias,
                    color: tokens.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.border),
                    ),
                    child: showAllMode && allPins.isNotEmpty
                        ? AspectRatio(
                            aspectRatio: 16 / 10,
                            child: _AllChildrenP13Map(
                              pins: allPins,
                              geofences: geofences,
                            ),
                          )
                        : ping != null
                            ? AspectRatio(
                                aspectRatio: 16 / 10,
                                child: ChildLocationMap(
                                  ping: ping,
                                  childName: focusedChild.displayName,
                                ),
                              )
                            : locationAsync.hasError
                                ? Padding(
                                    key: const ValueKey('p13LocationError'),
                                    padding: const EdgeInsets.all(AppSpace.lg),
                                    child: ErrorRetryView(
                                      message: friendlyErrorText(
                                        l10n,
                                        locationAsync.error!,
                                        () => l10n.familyLoadFailed,
                                      ),
                                      onRetry: () => ref.invalidate(locationProvider(focusedChild.id)),
                                    ),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.all(AppSpace.xl),
                                    child: Column(
                                      children: [
                                        Icon(
                                          Icons.location_off_outlined,
                                          size: 32,
                                          color: tokens.onSurfaceVariant,
                                        ),
                                        const SizedBox(height: AppSpace.sm),
                                        Text(
                                          l10n.locationP13NoLocationYet,
                                          textAlign: TextAlign.center,
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: tokens.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  // Place card in words (no "Live" badge, no route drawn on card)
                  Card(
                    key: const ValueKey('p13PlaceCard'),
                    color: tokens.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: tokens.primaryContainer,
                                foregroundColor: tokens.onPrimaryContainer,
                                child: Text(focusedChild.initials),
                              ),
                              const SizedBox(width: AppSpace.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      firstStrongIsolate(focusedChild.displayName),
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            color: tokens.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    if (ping != null) ...[
                                      const SizedBox(height: AppSpace.xxs),
                                      PlaceNameText(
                                        ping: ping,
                                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                              color: tokens.onSurface,
                                            ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (ping != null || (primaryDevice != null && primaryDevice.batteryPct > 0)) ...[
                            const SizedBox(height: AppSpace.sm),
                            Wrap(
                              spacing: AppSpace.md,
                              runSpacing: AppSpace.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (ping != null)
                                  FreshnessLine(
                                    timestamp: ping.timestamp,
                                    style: Theme.of(context).textTheme.bodySmall,
                                    suffix: accuracy != null ? l10n.accuracyShort(accuracy) : null,
                                  ),
                                if (primaryDevice != null && primaryDevice.batteryPct > 0)
                                  Row(
                                    key: const ValueKey('p13BatteryLabel'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        primaryDevice.batteryPct <= 20
                                            ? Icons.battery_alert_outlined
                                            : Icons.battery_std_outlined,
                                        size: 16,
                                        color: primaryDevice.batteryPct <= 20
                                            ? tokens.warn
                                            : tokens.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: AppSpace.xxs),
                                      Text(
                                        ltrIsolate('${primaryDevice.batteryPct}%'),
                                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                              color: primaryDevice.batteryPct <= 20
                                                  ? tokens.warn
                                                  : tokens.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: AppSpace.md),
                          // Actions: Refresh, Directions, Ring / Stop ringing (A2) or iOS unavailable (G6)
                          Wrap(
                            spacing: AppSpace.sm,
                            runSpacing: AppSpace.sm,
                            children: [
                              FilledButton.tonalIcon(
                                key: const ValueKey('p13RefreshButton'),
                                onPressed: _refreshing
                                    ? null
                                    : () => _refreshLocation(focusedChild, primaryDevice),
                                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                icon: _refreshing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.refresh, size: 18),
                                label: Text(
                                  _refreshing ? l10n.locationP13Refreshing : l10n.locationP13Refresh,
                                ),
                              ),
                              FilledButton.tonalIcon(
                                key: const ValueKey('p13DirectionsButton'),
                                onPressed: ping == null
                                    ? null
                                    : () => openInMaps(ping, Theme.of(context).platform),
                                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                icon: const Icon(Icons.directions_outlined, size: 18),
                                label: Text(l10n.locationP13Directions),
                              ),
                              FilledButton.tonalIcon(
                                key: const ValueKey('p13RingButton'),
                                onPressed: (primaryDevice == null || isIosDevice || _sendingCommand)
                                    ? null
                                    : () => _toggleRing(primaryDevice),
                                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                icon: Icon(
                                  isIosDevice
                                      ? Icons.phone_iphone_outlined
                                      : _ringSent
                                          ? Icons.notifications_off_outlined
                                          : Icons.notifications_active_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  isIosDevice
                                      ? l10n.locationP13RingNotYetOnIphone
                                      : (_ringSent ? l10n.commandStopRing : l10n.ring),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  // A7: "Earlier today" row under the place card (opens day's places sheet)
                  Card(
                    key: const ValueKey('p13EarlierTodayRow'),
                    color: tokens.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.border),
                    ),
                    child: ListTile(
                      minVerticalPadding: AppSpace.md,
                      leading: Icon(Icons.history, color: tokens.primary),
                      title: Text(l10n.locationP13EarlierToday),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openEarlierTodaySheet(focusedChild),
                    ),
                  ),
                  if (showAllMode) ...[
                    const SizedBox(height: AppSpace.md),
                    for (final c in children.where((x) => x.id != focusedChild.id))
                      _OtherChildLocationTile(
                        child: c,
                        device: overview.devicesFor(c.id).firstOrNull,
                        onTap: () => setState(() {
                          _selectedChildId = c.id;
                          _ringSent = false;
                        }),
                      ),
                  ],
                  const SizedBox(height: AppSpace.lg),
                  // A8: Saved places with alert state + Add place (keeps radius + enter/leave switches)
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpace.sm,
                    children: [
                      Text(
                        l10n.locationP13SavedPlacesTitle,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: tokens.onSurface,
                            ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('p13AddPlaceButton'),
                        onPressed: () => showGeofenceCreateDialog(
                          context,
                          children: children,
                          initialCenter: ping != null
                              ? LatLng(ping.lat, ping.lng)
                              : const LatLng(0, 0),
                        ),
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                        label: Text(l10n.locationP13AddPlace),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xs),
                  if (geofencesAsync.hasError && !geofencesAsync.hasValue)
                    Card(
                      key: const ValueKey('p13GeofencesError'),
                      color: tokens.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        side: BorderSide(color: tokens.border),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpace.md),
                        child: ErrorRetryView(
                          message: friendlyErrorText(
                            l10n,
                            geofencesAsync.error!,
                            () => l10n.familyLoadFailed,
                          ),
                          onRetry: () => ref.invalidate(geofencesProvider(focusedChild.id)),
                        ),
                      ),
                    )
                  else if (geofences.isEmpty)
                    Card(
                      color: tokens.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        side: BorderSide(color: tokens.border),
                      ),
                      child: ListTile(
                        leading: Icon(Icons.place_outlined, color: tokens.onSurfaceVariant),
                        title: Text(l10n.locationP13AddPlace),
                        onTap: () => showGeofenceCreateDialog(
                          context,
                          children: children,
                          initialCenter: ping != null
                              ? LatLng(ping.lat, ping.lng)
                              : const LatLng(0, 0),
                        ),
                      ),
                    )
                  else
                    for (final g in geofences)
                      Card(
                        key: ValueKey('p13SavedPlace-${g.id}'),
                        color: tokens.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          side: BorderSide(color: tokens.border),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.place_outlined, color: tokens.primary),
                          title: Text(firstStrongIsolate(g.label)),
                          subtitle: Text(
                            '${l10n.locationP13RadiusMeters(ltrIsolate('${g.radiusM.round()}'))} · ${_alertStateLabel(l10n, g)}',
                          ),
                        ),
                      ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _alertStateLabel(AppLocalizations l10n, Geofence g) {
    if (g.notifyOnEnter && g.notifyOnExit) return l10n.locationP13AlertsEnterLeave;
    if (g.notifyOnEnter) return l10n.locationP13AlertsEnterOnly;
    if (g.notifyOnExit) return l10n.locationP13AlertsLeaveOnly;
    return l10n.locationP13AlertsOff;
  }
}

class _AllChildrenP13Map extends StatefulWidget {
  final List<({Child child, LocationPing ping, Device? device})> pins;
  final List<Geofence> geofences;

  const _AllChildrenP13Map({
    required this.pins,
    required this.geofences,
  });

  @override
  State<_AllChildrenP13Map> createState() => _AllChildrenP13MapState();
}

class _AllChildrenP13MapState extends State<_AllChildrenP13Map> {
  GoogleMapController? _controller;
  bool _fitDone = false;

  void _maybeFit() {
    if (_fitDone || widget.pins.length < 2) return;
    _fitDone = true;
    unawaited(fitCameraToChildren(
      _controller,
      [for (final item in widget.pins) LatLng(item.ping.lat, item.ping.lng)],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.pins.first;
    final tokens = context.tokens;
    final useGoogle = mapIsAvailable(Theme.of(context).platform);
    if (!useGoogle) {
      final osmCoords = [
        for (final item in widget.pins) ll.LatLng(item.ping.lat, item.ping.lng),
      ];
      return fm.FlutterMap(
        key: const ValueKey('p13AllChildrenOsmMap'),
        options: fm.MapOptions(
          initialCenter: osmCoords.first,
          initialZoom: 13,
          initialCameraFit: osmCoords.length > 1
              ? fm.CameraFit.coordinates(
                  coordinates: osmCoords,
                  padding: const EdgeInsets.all(48),
                )
              : null,
        ),
        children: [
          fm.TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.osratech.parent',
          ),
          fm.CircleLayer(circles: [
            for (final item in widget.pins)
              if (item.ping.accuracyM > 0)
                fm.CircleMarker(
                  point: ll.LatLng(item.ping.lat, item.ping.lng),
                  radius: item.ping.accuracyM,
                  useRadiusInMeter: true,
                  color: tokens.primary.withValues(alpha: 0.12),
                  borderColor: tokens.primary,
                  borderStrokeWidth: 1,
                ),
            for (final fence in widget.geofences)
              fm.CircleMarker(
                point: ll.LatLng(fence.lat, fence.lng),
                radius: fence.radiusM,
                useRadiusInMeter: true,
                color: tokens.primary.withValues(alpha: 0.15),
                borderColor: tokens.primary,
                borderStrokeWidth: 1,
              ),
          ]),
          fm.MarkerLayer(markers: [
            for (final item in widget.pins)
              fm.Marker(
                point: ll.LatLng(item.ping.lat, item.ping.lng),
                width: (140 * MediaQuery.textScalerOf(context).scale(1.0)).clamp(140.0, 220.0),
                height: (72 * MediaQuery.textScalerOf(context).scale(1.0)).clamp(72.0, 144.0),
                alignment: Alignment.topCenter,
                child: Column(
                  key: ValueKey('osmPin-${item.child.id}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      elevation: 1,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text(
                          firstStrongIsolate(item.child.displayName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    OutlinedPin(color: tokens.primary),
                  ],
                ),
              ),
          ]),
          const OsmAttribution(),
        ],
      );
    }
    final markers = <Marker>{
      for (final item in widget.pins)
        Marker(
          markerId: MarkerId(item.child.id),
          position: LatLng(item.ping.lat, item.ping.lng),
          infoWindow: InfoWindow(title: item.child.displayName),
        ),
    };
    final circles = <Circle>{
      for (final item in widget.pins)
        if (item.ping.accuracyM > 0)
          Circle(
            circleId: CircleId('acc-${item.child.id}'),
            center: LatLng(item.ping.lat, item.ping.lng),
            radius: item.ping.accuracyM,
            fillColor: tokens.primary.withValues(alpha: 0.12),
            strokeColor: tokens.primary,
            strokeWidth: 1,
          ),
      for (final fence in widget.geofences)
        Circle(
          circleId: CircleId('fence-${fence.id}'),
          center: LatLng(fence.lat, fence.lng),
          radius: fence.radiusM,
          fillColor: tokens.primary.withValues(alpha: 0.15),
          strokeColor: tokens.primary,
          strokeWidth: 1,
        ),
    };
    return GoogleMap(
      key: const ValueKey('p13AllChildrenMap'),
      initialCameraPosition: CameraPosition(
        target: LatLng(first.ping.lat, first.ping.lng),
        zoom: 13,
      ),
      markers: markers,
      circles: circles,
      onMapCreated: (c) {
        _controller = c;
        _maybeFit();
      },
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
    );
  }
}

class _OtherChildLocationTile extends ConsumerWidget {
  final Child child;
  final Device? device;
  final VoidCallback onTap;

  const _OtherChildLocationTile({
    required this.child,
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final ping = ref.watch(locationProvider(child.id)).valueOrNull;
    return Card(
      key: ValueKey('p13OtherChild-${child.id}'),
      color: tokens.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: tokens.border),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: tokens.primaryContainer,
          foregroundColor: tokens.onPrimaryContainer,
          child: Text(child.initials),
        ),
        title: Text(firstStrongIsolate(child.displayName)),
        subtitle: ping != null
            ? PlaceNameText(ping: ping, maxLines: 1)
            : Text(context.l10n.locationP13NoLocationYet),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _EarlierTodaySheet extends ConsumerWidget {
  final Child child;
  final String title;
  const _EarlierTodaySheet({required this.child, required this.title});

  String _hhmm(DateTime? ts) {
    if (ts == null) return '';
    final local = ts.toLocal();
    return ltrIsolate(
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(locationHistoryProvider(child.id));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$title · ${firstStrongIsolate(child.displayName)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpace.sm),
            history.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpace.lg),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ErrorRetryView(
                message: friendlyErrorText(l10n, e, () => l10n.familyLoadFailed),
                onRetry: () => ref.invalidate(locationHistoryProvider(child.id)),
              ),
              data: (pings) {
                if (pings.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                    child: Text(l10n.locationP13EarlierTodayEmpty),
                  );
                }
                final newestFirst = pings.reversed.take(15).toList();
                return Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: newestFirst.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = newestFirst[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined, size: 18),
                        title: PlaceNameText(ping: p, maxLines: 1),
                        trailing: Text(_hhmm(p.timestamp)),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
