import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/locale_provider.dart';
import '../../providers/server_provider.dart';
import '../../theme/app_tokens.dart';
import '../dashboard/home_p07_screen.dart';

/// Build-time switch for UX Final Decisions P-01 Welcome (#1179).
/// Defaults to `false` so the legacy [WelcomeScreen] stays as fallback.
const bool kP01WelcomeDefault = bool.fromEnvironment(
  'OSRA_UX_P01',
  defaultValue: bool.fromEnvironment('OSRA_UX_FINAL', defaultValue: false),
);

/// Feature switch for P-01 Welcome (#1179).
final p01WelcomeEnabledProvider = Provider<bool>((ref) => kP01WelcomeDefault);

/// P-01 Welcome screen (#1179, Karim pick 0):
/// - Language switch on top (EN ↔ AR).
/// - 2×2 preview of the real P-07 Home tiles ([HomeP07PreviewTile]) labelled "Example" (no demo tooltips).
/// - Two buttons: Create account (`/create-account`) / Sign in (`/sign-in`).
/// - One no-ads line (no residency, speed, or "on-device" claims).
class WelcomeP01Screen extends ConsumerWidget {
  const WelcomeP01Screen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';

    Future<void> openCreateAccount() async {
      await ref.read(serverUrlProvider.notifier).ensureApplied();
      if (!context.mounted) return;
      final hasServer = builtInServerUrl() != null ||
          normalizeServerUrl(ref.read(serverUrlProvider)) != null;
      if (!hasServer) {
        // Unlocked build with no saved server: open Sign in first so the parent
        // can configure and validate the server URL before loading consent copy.
        await context.push('/sign-in');
        return;
      }
      await context.push('/create-account');
    }

    void openSignIn() {
      context.push('/sign-in');
    }

    final previewTiles = <HomeP07PreviewTile>[
      HomeP07PreviewTile(
        initials: isArabic ? 'ل' : 'L',
        childName: isArabic ? 'ليلى' : 'Layla',
        stateLabel: l10n.homeStateAtSchool,
        timeLeftText: l10n.p01PreviewScreenTimeValue,
        progress: 0.65,
        showExampleBadge: false,
      ),
      HomeP07PreviewTile(
        initials: isArabic ? 'ع' : 'O',
        childName: isArabic ? 'عمر' : 'Omar',
        stateLabel: l10n.homeStateBedtime,
        timeLeftText: firstStrongIsolate(l10n.p01PreviewBedtimeValue),
        progress: 0.90,
        showExampleBadge: false,
      ),
      HomeP07PreviewTile(
        initials: isArabic ? 'م' : 'M',
        childName: isArabic ? 'مريم' : 'Maya',
        stateLabel: l10n.homeStateHomework,
        timeLeftText: l10n.p01PreviewAppsValue,
        progress: 0.45,
        showExampleBadge: false,
      ),
      HomeP07PreviewTile(
        initials: isArabic ? 'ز' : 'Z',
        childName: isArabic ? 'زيد' : 'Zaid',
        stateLabel: l10n.homeStateFreeTime,
        timeLeftText: l10n.p01PreviewLocationValue,
        progress: 0.35,
        showExampleBadge: false,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: tokens.primary, size: 28),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          l10n.appName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: tokens.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('p01-language-switch'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        icon: const Icon(Icons.language, size: 18),
                        label: Text(isArabic ? 'English' : 'العربية'),
                        onPressed: () {
                          ref.read(localeProvider.notifier).setLocale(
                                isArabic ? const Locale('en') : const Locale('ar'),
                              );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xl),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.onboardingWelcomeTitle,
                      key: const ValueKey('p01-welcome-title'),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            color: tokens.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    l10n.p01WelcomeSubtitle,
                    key: const ValueKey('p01-welcome-subtitle'),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: tokens.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Row(
                    children: [
                      Container(
                        key: const ValueKey('p01-example-badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.sm,
                          vertical: AppSpace.xxs,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.primaryContainer,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          l10n.p01ExampleBadge,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: tokens.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  _ExampleHomeGrid(tiles: previewTiles),
                  const SizedBox(height: AppSpace.xl),
                  FilledButton(
                    key: const ValueKey('p01-create-account'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                    ),
                    onPressed: openCreateAccount,
                    child: Text(l10n.createAccount),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  OutlinedButton(
                    key: const ValueKey('p01-sign-in'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                    ),
                    onPressed: openSignIn,
                    child: Text(l10n.signIn),
                  ),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    l10n.p01NoAdsLine,
                    key: const ValueKey('p01-no-ads'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.onSurfaceVariant,
                        ),
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

class _ExampleHomeGrid extends StatelessWidget {
  final List<HomeP07PreviewTile> tiles;

  const _ExampleHomeGrid({required this.tiles});

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return LayoutBuilder(
      key: const ValueKey('p01-preview-grid'),
      builder: (context, constraints) {
        final twoCol = constraints.maxWidth >= 300 && scale < 1.6;
        final tileWidth = twoCol
            ? (constraints.maxWidth - AppSpace.sm) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: tileWidth,
                child: tile,
              ),
          ],
        );
      },
    );
  }
}
