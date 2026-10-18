import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../providers/family_provider.dart';

/// Human label for a command type from the durable queue
/// (`services/api/src/lib/deviceCommands.ts`).
String commandTypeLabel(String type) => switch (type) {
      'lock' => 'Lock',
      'unlock' => 'Unlock',
      'ring' => 'Ring',
      'stop_ring' => 'Stop ringing',
      'sos_clear' => 'Clear SOS',
      'pause' => 'Pause device',
      'resume' => 'Resume device',
      'pause_internet' => 'Pause internet',
      'resume_internet' => 'Resume internet',
      'bonus_time' => 'Bonus time',
      'wind_down' => 'Wind down',
      'locate_now' => 'Locate now',
      'rules_updated' => 'Rules update',
      'consent_granted' => 'Consent granted',
      'consent_revoked' => 'Consent revoked',
      _ => type.replaceAll('_', ' '),
    };

/// Parent-facing delivery wording. It never claims a command was "sent" or
/// executed before the device acked it: `delivered` is only a collection by
/// the agent, and `pending` has not reached the device at all.
String commandStatusLabel(String status) => switch (status) {
      'acked' => 'Confirmed by device',
      'delivered' => 'Delivered — awaiting device confirmation',
      'failed' => 'Failed on device',
      'expired' => 'Expired before delivery',
      _ => 'Pending — waiting for the device',
    };

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

String formatCommandTime(DateTime? at) => at == null
    ? 'time unknown'
    : DateFormat.yMMMd().add_Hm().format(at.toLocal());

/// Plan 3.6: per-device command delivery status, read from the durable queue's
/// parent-only history endpoint. Non-destructive; refresh with pull-to-refresh.
class CommandHistoryScreen extends ConsumerWidget {
  final String childId;
  const CommandHistoryScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(familyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Command delivery')),
      body: overview.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(
          title: 'Could not load this child',
          detail: '$e',
          onRetry: () => ref.invalidate(familyProvider),
        ),
        data: (data) {
          final devices = data.devicesFor(childId);
          if (devices.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No devices registered for this child',
                    textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'A command is confirmed only when the child device reports back. '
                'Delivered means the device collected it; it has not confirmed it ran.',
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
    final history = ref.watch(deviceCommandHistoryProvider(device.id));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                    'Could not load command history',
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
                    label: const Text('Retry'),
                  ),
                ],
              ),
              data: (commands) => commands.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No commands yet'),
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
    final color = commandStatusColor(context, command.status);
    final events = <String>[
      'Created ${formatCommandTime(command.createdAt)}',
      if (command.deliveredAt != null)
        'Delivered ${formatCommandTime(command.deliveredAt)}',
      if (command.ackedAt != null)
        'Confirmed ${formatCommandTime(command.ackedAt)}',
    ];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(commandStatusIcon(command.status), color: color, size: 20),
      title: Text(commandTypeLabel(command.type)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(commandStatusLabel(command.status),
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
                label: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
