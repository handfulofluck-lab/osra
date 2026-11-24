import 'package:flutter/material.dart';

import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// Neutral explanatory card shown for an iPhone child where Apple keeps
/// per-app lists and per-app minutes on the child's iPhone (#1046, UI/UX
/// Bureau 7120870405).
///
/// Uses `Icons.phone_iphone` and `colorScheme.surfaceContainer` (never an error
/// or warning icon/colour) so the state reads as a platform rule, not a fault.
class IphoneAppDetailsCard extends StatelessWidget {
  final String childName;
  const IphoneAppDetailsCard({super.key, required this.childName});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isolatedChild = firstStrongIsolate(childName);
    return Card(
      key: const ValueKey('iphoneAppDetailsCard'),
      color: colors.surfaceContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.phone_iphone,
                  key: const ValueKey('iphoneAppDetailsIcon'),
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    l10n.iphoneAppDetailsTitle(isolatedChild),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              l10n.iphoneAppDetailsBody(isolatedChild),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpace.md),
            FilledButton.tonal(
              key: const ValueKey('iphoneHowItWorksButton'),
              onPressed: () => showIphoneHowItWorksSheet(context, childName),
              child: Text(l10n.iphoneAppDetailsHowItWorks),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the 3-step explanation sheet for how app control and screen-time
/// checks work on a child's iPhone (#1046).
Future<void> showIphoneHowItWorksSheet(BuildContext context, String childName) {
  final isolatedChild = firstStrongIsolate(childName);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final l10n = ctx.l10n;
      final theme = Theme.of(ctx);
      final steps = [
        l10n.iphoneHowItWorksStep1(isolatedChild),
        l10n.iphoneHowItWorksStep2,
        l10n.iphoneHowItWorksStep3(isolatedChild),
      ];
      return SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('iphoneHowItWorksSheet'),
          padding: const EdgeInsetsDirectional.fromSTEB(
            AppSpace.xl,
            0,
            AppSpace.xl,
            AppSpace.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.phone_iphone, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      l10n.iphoneHowItWorksTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              for (var i = 0; i < steps.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpace.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}.',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        steps[i],
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpace.lg),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonal(
                  key: const ValueKey('iphoneHowItWorksClose'),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.close),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
