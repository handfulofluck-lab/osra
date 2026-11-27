import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'app_alert_presentation.dart';

const timeRequestActionsEnabled = bool.fromEnvironment(
  'OSRA_UX_P20',
  defaultValue: bool.fromEnvironment('OSRA_UX_FINAL', defaultValue: false),
);
const _actionSize = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(48, 48)),
);

class TimeRequestActions extends ConsumerStatefulWidget {
  final Alert alert;
  final ValueChanged<Alert>? onResolved;

  const TimeRequestActions({super.key, required this.alert, this.onResolved});

  @override
  ConsumerState<TimeRequestActions> createState() => _TimeRequestActionsState();
}

class _TimeRequestActionsState extends ConsumerState<TimeRequestActions> {
  bool _saving = false;
  bool _failed = false;
  bool _declining = false;
  Alert? _completed;

  Future<void> _submit(int? minutes) async {
    if (_saving || _completed != null || widget.alert.acknowledged) return;
    final alert = widget.alert;
    setState(() {
      _saving = true;
      _failed = false;
      _declining = minutes == null;
    });
    try {
      final response = await ref.read(apiClientProvider).raw.post(
        '/v1/alerts/${Uri.encodeComponent(alert.id)}/time-decision',
        data: {
          'action': minutes == null ? 'decline' : 'grant',
          if (minutes != null) 'minutes': minutes,
        },
      );
      final payload = response.data;
      final receipt = TimeRequestResolution.fromJson(
        payload is Map ? payload['resolution'] : null,
        ownSubmission: true,
      );
      if (receipt == null) {
        if (mounted) setState(() => _failed = true);
      } else {
        _complete(alert, receipt);
      }
    } on DioException catch (e) {
      final payload = e.response?.data;
      if (e.response?.statusCode == 409 &&
          payload is Map &&
          payload['error'] == 'time_request_already_resolved') {
        _complete(alert, TimeRequestResolution.fromJson(payload['resolution']));
      } else if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _complete(Alert alert, TimeRequestResolution? receipt) {
    if (!mounted) return;
    final updated = alert.copyWith(
      acknowledged: true,
      updatedAt: receipt?.resolvedAt,
      timeRequestResolution: receipt,
    );
    if (widget.alert.id == alert.id) setState(() => _completed = updated);
    widget.onResolved?.call(updated);
    ref.read(alertsSeenProvider.notifier).markAcknowledged(alert.id);
    ref.invalidate(alertsProvider);
    ref.invalidate(unacknowledgedAlertsProvider);
    ref.invalidate(unacknowledgedCountProvider);
    if (receipt?.grantedMinutes != null) {
      final devices =
          ref.read(familyProvider).valueOrNull?.devicesFor(alert.childId);
      ref.invalidate(rulesProvider(alert.childId));
      ref.invalidate(familyProvider);
      for (final device in devices ?? const <Device>[]) {
        ref.invalidate(deviceCommandHistoryProvider(device.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final alert = _completed ?? widget.alert;
    final receipt = alert.timeRequestResolution;
    if (alert.acknowledged || receipt != null) {
      final minutes = receipt?.grantedMinutes;
      final actor = firstStrongIsolate(receipt?.actorName ?? '');
      final message = switch ((receipt?.decidedByViewer, minutes)) {
        (true, null) => l10n.timeRequestDeclinedByYou,
        (true, final int granted) => l10n.timeRequestGrantedByYou(granted),
        (_, _) when receipt == null || receipt.actorName.isEmpty =>
          l10n.accessRequestHandled,
        (_, null) => l10n.timeRequestDeclinedBy(actor),
        (_, final int granted) => l10n.timeRequestGrantedBy(actor, granted),
      };
      final localTime = receipt == null
          ? null
          : formatTimeRequestTimestamp(
              context,
              receipt.resolvedAt,
              now: ref.watch(clockProvider)(),
            );
      return Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, key: const ValueKey('time-request-receipt')),
            if (localTime != null) Text(l10n.timeRequestDecidedAt(localTime)),
          ],
        ),
      );
    }

    final family = ref.watch(familyProvider).valueOrNull;
    final parent = family?.parent;
    final device =
        family?.devices.where((d) => d.id == alert.deviceId).firstOrNull;
    if (device != null && device.platform != 'android') {
      return Text(l10n.phoneSetupStateUnavailable);
    }
    final canDecide = parent != null &&
        (parent.role == 'owner' ||
            (parent.permissions.contains('alerts') &&
                parent.permissions.contains('rules')));
    if (!canDecide) return Text(l10n.readPermissionRequired);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_failed)
          Semantics(
            liveRegion: true,
            child: Text(_declining ? l10n.acknowledgeFailed : l10n.bonusFailed),
          ),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          children: [
            for (final minutes in [15, 30])
              FilledButton.tonal(
                key: ValueKey('time-request-grant-$minutes'),
                style: _actionSize,
                onPressed: _saving ? null : () => _submit(minutes),
                child: Text(l10n
                    .timeRequestGrant(ltrIsolate(normalizeDigits('$minutes')))),
              ),
            OutlinedButton(
              key: const ValueKey('time-request-decline'),
              style: _actionSize,
              onPressed: _saving ? null : () => _submit(null),
              child: Text(l10n.timeRequestDecline),
            ),
          ],
        ),
      ],
    );
  }
}
