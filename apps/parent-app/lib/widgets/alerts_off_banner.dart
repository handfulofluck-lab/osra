import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../push/notification_permission_service.dart';
import '../theme/app_tokens.dart';

/// Persistent Home banner shown whenever OS notifications are off (#1173).
///
/// Opens the app's system notification settings when the parent taps
/// `"Turn on alerts"`, and disappears automatically on `AppLifecycleState.resumed`
/// once notifications are enabled.
class AlertsOffBanner extends ConsumerWidget {
  final EdgeInsetsGeometry margin;

  const AlertsOffBanner({
    super.key,
    this.margin = const EdgeInsetsDirectional.fromSTEB(
      AppSpace.md,
      AppSpace.md,
      AppSpace.md,
      0,
    ),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(
      notificationPermissionControllerProvider.select((s) => s.showAlertsOffBanner),
    );
    if (!show) return const SizedBox.shrink();

    final l10n = context.l10n;
    final tokens = context.tokens;
    final text = Theme.of(context).textTheme;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final width = MediaQuery.sizeOf(context).width;
    final fullWidthAction = scale > 1.35 || width < 360;

    final actionButton = FilledButton.tonal(
      key: const ValueKey('alertsOffTurnOnButton'),
      style: FilledButton.styleFrom(
        minimumSize: Size(
          fullWidthAction ? double.infinity : kMinInteractiveDimension,
          48,
        ),
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.xs,
        ),
      ),
      onPressed: () {
        ref.read(notificationPermissionControllerProvider.notifier).openSettings();
      },
      child: Text(l10n.alertsOffTurnOnAction, textAlign: TextAlign.center),
    );

    return Card(
      key: const ValueKey('alertsOffBanner'),
      margin: margin,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: tokens.warn),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.notifications_off_outlined,
                    size: 20,
                    color: tokens.warn,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    l10n.alertsOffBannerBody,
                    style: text.bodyMedium?.copyWith(color: tokens.onSurface),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            if (fullWidthAction)
              actionButton
            else
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: actionButton,
              ),
          ],
        ),
      ),
    );
  }
}