import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_tokens.dart';
import '../children/phone_setup_section.dart';

/// Final wizard step. It completes only for the child being onboarded and only
/// after the phone explicitly confirms every required grant. Other devices and
/// recommendations never fabricate completion.
class SetupDoneScreen extends ConsumerStatefulWidget {
  const SetupDoneScreen({
    super.key,
    @visibleForTesting this.liveRefreshInterval = const Duration(seconds: 30),
  });

  final Duration liveRefreshInterval;

  static const _androidRequiredGrants = [
    'accessibility',
    'usage_access',
    'overlay',
    'device_admin',
    'web_filter',
    'location',
    'private_dns',
  ];

  static List<String> _requiredGrantsFor(Device device) => [
        ..._androidRequiredGrants,
        if (device.capabilityFlavour == 'full') 'notification_listener',
      ];

  @override
  ConsumerState<SetupDoneScreen> createState() => _SetupDoneScreenState();
}

class _SetupDoneScreenState extends ConsumerState<SetupDoneScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (widget.liveRefreshInterval > Duration.zero) {
      _refreshTimer =
          Timer.periodic(widget.liveRefreshInterval, (_) => _refreshFamily());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshFamily() async {
    ref.invalidate(familyProvider);
    try {
      await ref.read(familyProvider.future);
    } catch (_) {
      // The provider's existing error state explains the failed refresh.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final onboarding = ref.watch(onboardingProvider);
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
        child: RefreshIndicator(
          onRefresh: _refreshFamily,
          child: ref.watch(familyProvider).when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stack) =>
                    Center(child: Text(l10n.onboardingDonePendingBody)),
                data: (overview) {
                  final childId = onboarding.childId;
                  final devices = overview.devices
                      .where((device) => device.childId == childId)
                      .toList();
                  if (childId == null || devices.length != 1) {
                    return _PendingBody(
                      title: l10n.onboardingDonePendingTitle,
                      body: l10n.onboardingDonePendingBody,
                      button: l10n.onboardingGoToDashboard,
                      tokens: tokens,
                    );
                  }
                  final child = overview.children
                      .where((item) => item.id == childId)
                      .firstOrNull;
                  final childName = child?.displayName ?? '';
                  final device = devices.first;
                  final isIos = device.platform.toLowerCase() == 'ios';
                  final isAndroid = device.platform.toLowerCase() == 'android';
                  final requiredGrants = isIos
                      ? const ['family_controls', 'background_refresh']
                      : SetupDoneScreen._requiredGrantsFor(device);
                  final confirmed = requiredGrants
                      .where((key) => device.capabilityGrants[key] == 'granted')
                      .length;
                  final complete = isAndroid &&
                      device.capabilityFlavour.isNotEmpty &&
                      confirmed == requiredGrants.length;
                  return SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(AppSpace.xl),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ExcludeSemantics(
                            child: LinearProgressIndicator(
                              value: confirmed / requiredGrants.length,
                              minHeight: 4,
                              color: complete ? tokens.ok : tokens.primary,
                              backgroundColor: tokens.surfaceContainer,
                            ),
                          ),
                          const SizedBox(height: AppSpace.lg),
                          Semantics(
                            header: true,
                            child: Text(
                              l10n.p06ProgressTitle(
                                  firstStrongIsolate(childName)),
                              key: const ValueKey('onboardingDoneTitle'),
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          Text(
                            l10n.p06ProgressCount(
                              ltrIsolate('$confirmed'),
                              ltrIsolate('${requiredGrants.length}'),
                            ),
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: AppSpace.lg),
                          for (final key in requiredGrants)
                            _GrantRow(
                              grant: key,
                              label: PhoneSetupSection.grantLabel(l10n, key),
                              state: device.capabilityGrants[key] == 'granted'
                                  ? l10n.p06ConfirmedOnPhone
                                  : l10n.p06WaitingForPhone,
                              confirmed:
                                  device.capabilityGrants[key] == 'granted',
                              unavailable: false,
                            ),
                          if (device.capabilityGrants['battery'] == 'missing')
                            _WarningRow(
                                text: l10n.p06BatteryWarning, tokens: tokens),
                          const SizedBox(height: AppSpace.md),
                          OutlinedButton.icon(
                            onPressed: () => _showGuide(context, childName),
                            icon: const Icon(Icons.help_outline),
                            label: Text(l10n.p06ShowMeHow),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          FilledButton(
                            key: const ValueKey('onboardingFinish'),
                            onPressed: () {
                              ref
                                  .read(onboardingProvider.notifier)
                                  .completeSetup();
                              context.go('/');
                            },
                            child: Text(complete
                                ? l10n.familyDone
                                : l10n.onboardingGoToDashboard),
                          ),
                          ExpansionTile(
                            title: Text(l10n.phoneSetupTitle),
                            children: [
                              PhoneSetupSection(
                                  device: device, childName: childName)
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
        ),
      ),
    );
  }

  void _showGuide(BuildContext context, String childName) {
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.p06GuideTitle(firstStrongIsolate(childName))),
        content: Text(l10n.p06GuideBody(firstStrongIsolate(childName))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }
}

class _GrantRow extends StatelessWidget {
  final String grant;
  final String label;
  final String state;
  final bool confirmed;
  final bool unavailable;

  const _GrantRow({
    required this.grant,
    required this.label,
    required this.state,
    required this.confirmed,
    required this.unavailable,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = unavailable
        ? Theme.of(context).disabledColor
        : confirmed
            ? tokens.ok
            : tokens.warn;
    return Padding(
      key: ValueKey('p06-grant-$grant'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            unavailable
                ? Icons.block
                : confirmed
                    ? Icons.check_circle_outline
                    : Icons.schedule,
            color: color,
            size: 20,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyLarge),
                Text(state,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  final String text;
  final AppTokens tokens;
  const _WarningRow({required this.text, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Icon(Icons.battery_alert_outlined, color: tokens.warn),
          const SizedBox(width: AppSpace.sm),
          Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _PendingBody extends StatelessWidget {
  final String title;
  final String body;
  final String button;
  final AppTokens tokens;
  const _PendingBody({
    required this.title,
    required this.body,
    required this.button,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
                child: Icon(Icons.schedule, size: 64, color: tokens.warn)),
            const SizedBox(height: AppSpace.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: AppSpace.sm),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              key: const ValueKey('onboardingFinish'),
              onPressed: () {
                final container = ProviderScope.containerOf(context);
                container.read(onboardingProvider.notifier).completeSetup();
                context.go('/');
              },
              child: Text(button),
            ),
          ],
        ),
      ),
    );
  }
}
