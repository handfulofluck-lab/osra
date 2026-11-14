import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// The SOS alert detail's actions, in the order a parent reads them.
///
/// #743 UI/UX review, three rules that are easy to get wrong and were:
///
/// 1. **One filled button, and it is the one that works.** On a build whose in-app map cannot draw
///    (#598/#707) `Show on map` leads to a screen that says "Not available", so it is not shown at all and
///    the phone's own maps app takes the filled slot. A prominent button that goes nowhere is worse than no
///    prominent button.
/// 2. **The stacked order is set here, not inherited from the action row**: filled first, then the quiet
///    action, then Close (which the dialog adds itself, last). At 360 px these stack.
/// 3. This is a builder rather than a widget so the dialog's `actions:` layout is untouched — the buttons
///    stay direct children of `AlertDialog`, which is what keeps them in one action row on a wide screen.
///
/// It is a separate function so both branches can be pumped by a test: `mapAvailable` arrives as a
/// parameter rather than being read from a compile-time constant inside the widget.
List<Widget> sosAlertActions({
  required AppLocalizations l10n,
  required bool mapAvailable,
  required VoidCallback onShowOnMap,
  required VoidCallback onOpenInMaps,
  required VoidCallback onCopy,
}) =>
    [
      if (mapAvailable)
        FilledButton.icon(
          key: const ValueKey('alert-show-on-map'),
          onPressed: onShowOnMap,
          icon: const Icon(Icons.place),
          label: Text(l10n.alertShowOnMap),
        )
      else
        FilledButton.icon(
          key: const ValueKey('alert-open-in-maps'),
          onPressed: onOpenInMaps,
          icon: const Icon(Icons.map_outlined),
          label: Text(l10n.alertOpenInMaps),
        ),
      TextButton.icon(
        key: const ValueKey('alert-copy-coordinates'),
        onPressed: onCopy,
        icon: const Icon(Icons.copy, size: 18),
        label: Text(l10n.alertCopyCoordinates),
      ),
    ];
