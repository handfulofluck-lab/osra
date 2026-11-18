import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_tokens.dart';

/// Shared R-ID-1 full-screen / card error body with a localized message and Retry action.
class ErrorRetryView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final IconData icon;

  const ErrorRetryView({
    super.key,
    required this.message,
    required this.onRetry,
    this.icon = Icons.cloud_off_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpace.sm),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpace.md),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a one-off failure SnackBar, optionally offering a Retry action.
void showErrorSnackBar(
  BuildContext context,
  String message, {
  VoidCallback? onRetry,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: onRetry == null
          ? null
          : SnackBarAction(
              label: context.l10n.retry,
              onPressed: onRetry,
            ),
    ),
  );
}
