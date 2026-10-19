import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_tokens.dart';

/// First screen of the first-run wizard. One primary action: start the account
/// step. This is the only screen a fresh install can reach, and it never
/// pretends setup has happened.
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
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
                  ExcludeSemantics(child: Icon(Icons.shield_outlined, size: 72)),
                  const SizedBox(height: AppSpace.lg),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.onboardingWelcomeTitle,
                      key: const ValueKey('onboardingWelcomeTitle'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    l10n.onboardingWelcomeBody,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: AppSpace.xl),
                  FilledButton.icon(
                    key: const ValueKey('onboardingGetStarted'),
                    onPressed: () {
                      ref.read(onboardingProvider.notifier).begin();
                      context.go('/sign-in');
                    },
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(l10n.onboardingGetStarted),
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
