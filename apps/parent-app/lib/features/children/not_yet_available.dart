import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// #1088 (epic #1092): controls a child's build cannot run yet, drawn as "Not yet available".
///
/// The list comes from the server's static capability table (`DeviceSetup.unsupportedCommands`,
/// `services/api/src/lib/capabilityTable.ts`), never from `platform == 'ios'`. When a row of that table is
/// emptied (Ring with #760, Lock and Pause with #1089) the control comes back by itself, with no app change.
///
/// UI/UX Bureau treatment (#1088, 7146060347): the control keeps its place and icon, is drawn at 38% content
/// opacity with no tonal fill, carries a neutral "Not yet available" pill, and stays tappable: a tap explains
/// why in a snackbar and never sends a command. No red or warning colour, and no date is promised.

/// The parent-facing actions, in the order the card line names them. Each one covers a command and its undo.
const List<String> notYetActionOrder = ['lock', 'pause', 'pause_internet', 'ring'];

/// The command (and its undo) each action stands for.
const Map<String, List<String>> _actionCommands = {
  'lock': ['lock', 'unlock'],
  'pause': ['pause', 'resume'],
  'pause_internet': ['pause_internet', 'resume_internet'],
  'ring': ['ring', 'stop_ring'],
};

/// Which action a command belongs to, or null for a command this file does not grey out.
String? notYetActionFor(String command) {
  for (final e in _actionCommands.entries) {
    if (e.value.contains(command)) return e.key;
  }
  return null;
}

/// True when the server says [device]'s build cannot run [command].
bool isCommandNotYetAvailable(Device device, String command) =>
    device.setup?.unsupportedCommands.contains(command) ?? false;

/// The actions on [device] that are not yet available, in [notYetActionOrder].
List<String> notYetActions(Device device) => [
      for (final action in notYetActionOrder)
        if (_actionCommands[action]!.any((c) => isCommandNotYetAvailable(device, c))) action,
    ];

/// The localized name of an action, as the buttons already label it.
String notYetActionLabel(AppLocalizations l10n, String action) => switch (action) {
      'lock' => l10n.lock,
      'pause' => l10n.commandPauseDevice,
      'pause_internet' => l10n.commandPauseInternet,
      'ring' => l10n.ring,
      _ => action,
    };

/// Joins action names with the locale's separator and final conjunction ("Lock, Pause and Ring").
String joinNotYetActions(AppLocalizations l10n, List<String> labels) {
  if (labels.isEmpty) return '';
  if (labels.length == 1) return labels.single;
  final rest = labels.sublist(0, labels.length - 1).join(l10n.iosNotYetListSeparator);
  return l10n.iosNotYetListLast(rest, labels.last);
}

/// The snackbar a tap on a not-yet control shows. It never sends a command.
void showNotYetSnackBar(BuildContext context, String actionLabel) {
  final l10n = context.l10n;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(l10n.iosNotYetTapSnack(actionLabel))));
}

/// A device control that is not yet available on this build: same place, same icon, 38% content, a pill.
class NotYetAvailableButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String actionLabel;

  const NotYetAvailableButton({
    super.key,
    required this.icon,
    required this.label,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final faded = scheme.onSurface.withValues(alpha: 0.38);
    return Semantics(
      button: true,
      label: l10n.iosNotYetA11y(actionLabel),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => showNotYetSnackBar(context, actionLabel),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.transparent,
              foregroundColor: faded,
              iconColor: faded,
              elevation: 0,
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.sm),
              alignment: AlignmentDirectional.centerStart,
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            icon: Icon(icon, size: 18),
            label: Text(label, softWrap: true),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: const NotYetPill(),
          ),
        ],
      ),
    );
  }
}

/// The small neutral "Not yet available" pill.
class NotYetPill extends StatelessWidget {
  const NotYetPill({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsetsDirectional.only(start: AppSpace.sm, top: 2),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        context.l10n.iosNotYetPill,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// The one line under the device row: what is not yet available, and what works now. Shown only when at
/// least one control on this device is not yet available.
class NotYetCardLine extends StatelessWidget {
  final Device device;
  final String childName;

  const NotYetCardLine({super.key, required this.device, required this.childName});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final actions = notYetActions(device);
    if (actions.isEmpty) return const SizedBox.shrink();
    final joined = joinNotYetActions(l10n, [for (final a in actions) notYetActionLabel(l10n, a)]);
    return Padding(
      key: ValueKey('notYetCardLine-${device.id}'),
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xs),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          l10n.iosNotYetCardLine(childName, joined),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
