import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_tokens.dart';

/// Final wizard step. It only says the setup is complete when a device was
/// actually confirmed; a skipped pairing gets "one step left" copy and leaves
/// the dashboard affordance in place.
class SetupDoneScreen extends ConsumerWidget {
  const SetupDoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final onboarding = ref.watch(onboardingProvider);
    final pending = onboarding.pairingPending;
    final tokens = context.tokens;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.onboardingDoneStepTitle),
        leading: BackButton(onPressed: () {
          ref.read(onboardingProvider.notifier).backToPairing();
          context.go('/setup/pair');
        }),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      pending ? Icons.schedule : Icons.check_circle_outline,
                      size: 64,
                      color: pending ? tokens.warn : tokens.ok,
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Semantics(
                    header: true,
                    child: Text(
                      pending ? l10n.onboardingDonePendingTitle : l10n.onboardingDoneTitle,
                      key: const ValueKey('onboardingDoneTitle'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    pending ? l10n.onboardingDonePendingBody : l10n.onboardingDoneBody,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: AppSpace.xl),
                  FilledButton(
                    key: const ValueKey('onboardingFinish'),
                    onPressed: () {
                      ref.read(onboardingProvider.notifier).completeSetup();
                      context.go('/');
                    },
                    child: Text(l10n.onboardingGoToDashboard),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
