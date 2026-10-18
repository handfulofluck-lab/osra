import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';

IconData commandStatusIcon(String status) => switch (status) {
      'acked' => Icons.check_circle,
      'delivered' => Icons.cloud_done,
      'failed' => Icons.error,
      'expired' => Icons.history_toggle_off,
      _ => Icons.schedule,
    };

Color commandStatusColor(BuildContext context, String status) =>
    switch (status) {
      'acked' => Colors.green.shade700,
      'delivered' => Colors.blue.shade700,
      'failed' => Theme.of(context).colorScheme.error,
      'expired' => Colors.grey.shade600,
      _ => Colors.amber.shade800,
    };

String formatCommandTime(BuildContext context, DateTime? at) => at == null
    ? context.l10n.timeUnknown
    : DateFormat.yMMMd(context.localeName).add_Hm().format(at.toLocal());

/// Plan 3.6: per-device command delivery status, read from the durable queue's
/// parent-only history endpoint. Non-destructive; refresh with pull-to-refresh.
class CommandHistoryScreen extends ConsumerWidget {
  final String childId;
  const CommandHistoryScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final overview = ref.watch(familyProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.commandDeliveryTitle)),
      body: overview.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(
          title: l10n.couldNotLoadChild,
          detail: '$e',
          onRetry: () => ref.invalidate(familyProvider),
        ),
        data: (data) {
          final devices = data.devicesFor(childId);
          if (devices.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.noDevicesForChild,
                    textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                l10n.deliveryExplanation,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final device in devices) ...[
                _DeviceCommandSection(device: device),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DeviceCommandSection extends ConsumerWidget {
  final Device device;
  const _DeviceCommandSection({required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(deviceCommandHistoryProvider(device.id));
    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (device.platform) {
                    'android' => Icons.android,
                    'ios' => Icons.apple,
                    _ => Icons.devices_other,
                  },
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    device.model,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            history.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    l10n.couldNotLoadCommandHistory,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  const SizedBox(height: 2),
                  Text('$e',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis),
                  TextButton.icon(
                    onPressed: () =>
                        ref.invalidate(deviceCommandHistoryProvider(device.id)),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.retry),
                  ),
                ],
              ),
              data: (commands) => commands.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(l10n.noCommandsYet),
                    )
                  : Column(
                      children: [
                        for (final command in commands)
                          _CommandTile(command: command),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  final DeviceCommand command;
  const _CommandTile({required this.command});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final color = commandStatusColor(context, command.status);
    final events = <String>[
      l10n.createdEvent(formatCommandTime(context, command.createdAt)),
      if (command.deliveredAt != null)
        l10n.deliveredEvent(formatCommandTime(context, command.deliveredAt)),
      if (command.ackedAt != null)
        l10n.confirmedEvent(formatCommandTime(context, command.ackedAt)),
    ];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(commandStatusIcon(command.status), color: color, size: 20),
      title: Text(l10n.commandType(command.type)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.commandStatus(command.status),
              style: TextStyle(color: color)),
          Text(events.join(' · '),
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String title;
  final String detail;
  final VoidCallback onRetry;
  const _ErrorState(
      {required this.title, required this.detail, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 8),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(detail,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.retry)),
          ],
        ),
      ),
    );
  }
}
