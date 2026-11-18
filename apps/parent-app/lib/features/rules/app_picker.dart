import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// U33 (#868): the one picker every app choice in the parent app opens.
///
/// A full-screen multi-select list of the child's own reported apps — real icon (or a letter avatar
/// until the icon arrives), the app's name, a checkbox at the end of the row. No package id is ever
/// shown, and there is no text-field fallback: an inventory that has not arrived says so and stops.
///
/// [disabled] maps a package id to the reason its row cannot be chosen ("already blocked", an
/// essential app); the caller owns that wording. [pinnedFirst] lifts package ids to the top of their
/// group, which is how the payment-app shortcut opens with the wallet apps a phone actually has.
/// Returns the chosen apps (with their labels), or null when the parent backs out.
Future<List<InstalledApp>?> showAppPicker(
  BuildContext context, {
  required String childId,
  String? childName,
  Set<String> selected = const {},
  Map<String, String> disabled = const {},
  List<String> pinnedFirst = const [],
}) {
  return Navigator.of(context).push<List<InstalledApp>>(
    MaterialPageRoute<List<InstalledApp>>(
      fullscreenDialog: true,
      builder: (_) => AppPicker(
        childId: childId,
        childName: childName,
        initialSelection: selected,
        disabled: disabled,
        pinnedFirst: pinnedFirst,
      ),
    ),
  );
}

class AppPicker extends ConsumerStatefulWidget {
  final String childId;
  final String? childName;
  final Set<String> initialSelection;
  final Map<String, String> disabled;
  final List<String> pinnedFirst;

  const AppPicker({
    super.key,
    required this.childId,
    this.childName,
    this.initialSelection = const {},
    this.disabled = const {},
    this.pinnedFirst = const [],
  });

  @override
  ConsumerState<AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends ConsumerState<AppPicker> {
  final _search = TextEditingController();
  String _query = '';
  bool _showSystem = false;
  late final Set<String> _chosen = {...widget.initialSelection};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(InstalledApp app) {
    setState(() {
      if (!_chosen.remove(app.packageId)) _chosen.add(app.packageId);
    });
  }

  /// The chosen ids resolved to the apps the devices reported, in the list's order. An id that no
  /// device reports (a rule saved before this picker existed) keeps its id as its label — the one
  /// place a raw id can still surface, and only for what is already saved.
  List<InstalledApp> _result(List<DeviceApps> groups) {
    final byId = <String, InstalledApp>{};
    for (final group in groups) {
      for (final app in group.report.apps) {
        byId.putIfAbsent(app.packageId, () => app);
      }
    }
    return [
      for (final id in _chosen)
        byId[id] ?? InstalledApp(packageId: id, label: id),
    ];
  }

  List<InstalledApp> _visible(List<InstalledApp> apps) {
    final query = _query.trim().toLowerCase();
    final pinned = {for (final id in widget.pinnedFirst) id};
    final shown = [
      for (final app in apps)
        if ((_showSystem || !app.isSystem) &&
            (query.isEmpty || app.label.toLowerCase().contains(query)))
          app,
    ];
    shown.sort((a, b) {
      final aPinned = pinned.contains(a.packageId);
      final bPinned = pinned.contains(b.packageId);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return shown;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final groups = ref.watch(installedAppsByDeviceProvider(widget.childId));
    return Scaffold(
      key: const ValueKey('appPicker'),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.installedAppsTitle),
            if (widget.childName != null && widget.childName!.trim().isNotEmpty)
              Text(widget.childName!.trim(), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: groups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.installedAppsLoadFailed, textAlign: TextAlign.center),
                const SizedBox(height: AppSpace.sm),
                TextButton(
                  onPressed: () {
                    // The provider awaits familyProvider; invalidate both or the retry re-awaits
                    // the same cached family error.
                    ref.invalidate(familyProvider);
                    ref.invalidate(installedAppsByDeviceProvider(widget.childId));
                  },
                  child: Text(l10n.retry),
                ),
              ],
            ),
          ),
        ),
        data: (data) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.xs),
              child: TextField(
                key: const ValueKey('appPickerSearch'),
                controller: _search,
                decoration: InputDecoration(
                  labelText: l10n.searchApps,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: FilterChip(
                  key: const ValueKey('appPickerSystemFilter'),
                  label: Text(l10n.showSystemApps),
                  selected: _showSystem,
                  onSelected: (v) => setState(() => _showSystem = v),
                ),
              ),
            ),
            Expanded(child: _body(data)),
            _ConfirmBar(
              // The count waits for the Arabic Bureau's plural line ("Add {n} apps"); until then the
              // bar is disabled at zero and an empty list cannot be confirmed.
              onConfirm: _chosen.isEmpty ? null : () => Navigator.of(context).pop(_result(data)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(List<DeviceApps> groups) {
    final l10n = context.l10n;
    // #872 condition 4 (UI/UX Bureau): a device that reports nothing keeps its group header with the
    // "no apps reported yet" line under it, so a second phone never disappears from the list. Only a
    // device with apps that the search filtered out is skipped — that is the search working, not a gap.
    // A single device that has never reported keeps the original empty state (title + "appears after
    // the next check-in"): there is no second phone to lose, and that is the sentence a parent needs.
    // Condition 4 is about the multi-device list, where skipping an empty group made a phone vanish.
    if (groups.isEmpty || (groups.length == 1 && groups.single.report.apps.isEmpty)) {
      return ListView(
        key: const ValueKey('appPickerEmpty'),
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(l10n.installedAppsEmpty, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.xs),
          Text(l10n.installedAppsEmptyHint, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }
    final multiDevice = groups.length > 1;
    final rows = <Widget>[];
    for (final group in groups) {
      final visible = _visible(group.report.apps);
      if (visible.isEmpty && group.report.apps.isNotEmpty) continue;
      // With one device the list needs no header; with several, each device's apps are grouped under
      // the device that reported them, and the same app ticked in one group is ticked in the other.
      if (multiDevice) {
        rows.add(Padding(
          key: ValueKey('appPickerGroup-${group.deviceId}'),
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.xs),
          child: Text(group.label, style: Theme.of(context).textTheme.titleSmall),
        ));
      }
      // #872 condition 3 (UI/UX Bureau): the truncation notice belongs above the apps it describes, per
      // device, so a list cut short is not read as a definitive "this app is not installed".
      if (group.report.truncated) {
        rows.add(Padding(
          key: ValueKey('appPickerTruncated-${group.deviceId}'),
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xs),
          child: Text(
            l10n.installedAppsTruncated(group.report.apps.length),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ));
      }
      if (group.report.apps.isEmpty) {
        rows.add(Padding(
          key: ValueKey('appPickerGroupEmpty-${group.deviceId}'),
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
          child: Text(l10n.installedAppsEmpty, style: Theme.of(context).textTheme.bodySmall),
        ));
      } else {
        rows.addAll([for (final app in visible) _row(app)]);
      }
    }
    if (rows.isEmpty) {
      return ListView(
        key: const ValueKey('appPickerNoMatch'),
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [Text(l10n.installedAppsNoMatch)],
      );
    }
    return ListView(
      key: const ValueKey('appPickerList'),
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      children: rows,
    );
  }

  Widget _row(InstalledApp app) {
    final l10n = context.l10n;
    // Issue #199 item 5: a package the phone reported as essential is "Always allowed (needed for
    // calls and safety)" and cannot take a rule — a rule on the dialer would silently do nothing.
    final essential = app.essential == true;
    final reason = widget.disabled[app.packageId];
    final locked = essential || reason != null;
    final checked = _chosen.contains(app.packageId);
    return ListTile(
      key: ValueKey('appPickerRow-${app.packageId}'),
      enabled: !locked,
      leading: AppIconBadge(app: app, size: 40),
      title: Text(app.label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: essential
          ? Text(l10n.essentialAppRow)
          : reason != null
              ? Text(reason)
              : null,
      trailing: Checkbox(
        key: ValueKey('appPickerCheck-${app.packageId}'),
        value: checked,
        onChanged: locked ? null : (_) => _toggle(app),
      ),
      onTap: locked ? null : () => _toggle(app),
    );
  }
}

class _ConfirmBar extends StatelessWidget {
  final VoidCallback? onConfirm;

  const _ConfirmBar({this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        // #862 UI/UX addendum applies here too: 52 is a floor, so the confirm button grows with its
        // label at the largest text instead of cutting it.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('appPickerConfirm'),
              onPressed: onConfirm,
              // #872 condition 5 (UI/UX Bureau): "Add app" is a lie once several are ticked, and the
              // plural line ("Add {n} apps") is the Language Bureaus' to issue. Until it arrives, the
              // existing "Save" is the honest label.
              child: Text(context.l10n.save, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}

/// The avatar letter: the first code point of the name, uppercased, or `?` for an empty name. A rune
/// keeps a surrogate pair (an emoji or a non-BMP letter) whole where `substring(0, 1)` would split it.
String _firstLetter(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}

/// The app's real icon when one has arrived, otherwise a letter avatar in the brand tint (U33: never a
/// blank square). The letter is the first character of the name, which reads the same in every script.
class AppIconBadge extends StatelessWidget {
  final InstalledApp app;
  final double size;

  const AppIconBadge({super.key, required this.app, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letter = _firstLetter(app.label);
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.45,
        ),
      ),
    );
    final url = app.iconUrl;
    if (url == null) return avatar;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // An icon that fails to load (offline, a stale URL) falls back to the avatar rather than
        // leaving a broken image in the row.
        errorBuilder: (_, __, ___) => avatar,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : avatar,
      ),
    );
  }
}
