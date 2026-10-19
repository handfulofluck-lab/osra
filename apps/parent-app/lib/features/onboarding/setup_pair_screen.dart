import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_tokens.dart';
import '../pairing/pair_qr_screen.dart';

/// A fresh family read for the pair step. The shared [familyProvider] may
/// still hold the account's pre-add snapshot when the route arrives straight
/// from child creation, which made the step believe there was no child.
final setupFamilyProvider = FutureProvider.autoDispose<FamilyOverview>((ref) async {
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/family/me');
  return FamilyOverview.fromJson(Map<String, dynamic>.from(res.data as Map));
});

/// Wizard step 3: reuse [PairingQrScreen] against the child from the previous
/// step. The screen itself owns the code, countdown and server-verified
/// "Continue"; this wrapper only resolves which child and where to go next.
class SetupPairScreen extends ConsumerWidget {
  const SetupPairScreen({super.key, this.clock});

  /// Test seam forwarded to [PairingQrScreen].
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final family = ref.watch(setupFamilyProvider);
    final preferredId = ref.watch(onboardingProvider).childId;
    return family.when(
      loading: () => Scaffold(
        appBar: AppBar(
          title: Text(l10n.onboardingPairTitle),
          leading: BackButton(onPressed: () => _backToChild(ref, context)),
        ),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => Scaffold(
        appBar: AppBar(
          title: Text(l10n.onboardingPairTitle),
          leading: BackButton(onPressed: () => _backToChild(ref, context)),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.onboardingNoNetwork, textAlign: TextAlign.center),
                const SizedBox(height: AppSpace.md),
                FilledButton.tonal(
                  onPressed: () => ref.invalidate(setupFamilyProvider),
                  child: Text(l10n.tryAgain),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (overview) {
        final child = _resolveChild(overview, preferredId);
        if (child == null) {
          // A fresh read with no child is a real dead end: return to the step
          // that creates one instead of showing a code for nobody.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(onboardingProvider.notifier).backToChild();
            if (context.mounted) context.go('/setup/child');
          });
          return Scaffold(
            appBar: AppBar(title: Text(l10n.onboardingPairTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (preferredId != child.id) {
          // Keep the resume target in sync when the account already had a child
          // and the wizard resolved one instead of creating it.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(onboardingProvider.notifier).childAdded(child.id);
          });
        }
        return PairingQrScreen(
          childId: child.id,
          clock: clock,
          onboarding: true,
          childName: child.displayName,
          onBack: () => _backToChild(ref, context),
          onContinue: () {
            ref.read(onboardingProvider.notifier).pairingFinished();
            context.go('/setup/done');
          },
          onSkip: () {
            ref.read(onboardingProvider.notifier).pairingSkipped(childId: child.id);
            context.go('/setup/done');
          },
        );
      },
    );
  }

  static Child? _resolveChild(FamilyOverview overview, String? preferredId) {
    if (overview.children.isEmpty) return null;
    for (final child in overview.children) {
      if (child.id == preferredId) return child;
    }
    return overview.children.first;
  }

  static void _backToChild(WidgetRef ref, BuildContext context) {
    ref.read(onboardingProvider.notifier).backToChild();
    context.go('/setup/child');
  }
}
