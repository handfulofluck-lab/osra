import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../dashboard/dashboard_screen.dart' show formatLastSeen;

/// ADR-0034 decision 3 — "Phone setup": what this phone says it can do, and what is missing.
///
/// The states are the **phone's own verdict** (`CapabilitiesPolicy` on the device), with one exception:
/// `not_supported` is the *server's* word from its static table, so it reads as "not in this version" rather
/// than as a fault of the phone. A feature the device never mentioned is **not shown at all** — a build that
/// cannot do something omits the key instead of claiming it, and a blank is more honest than "not available".
///
/// Nothing here is derived: the parent app repeats what the agent reported, the same way the agent's lock
/// verdict is the one a `lock` command obeys.
class PhoneSetupSection extends StatelessWidget {
  final Device device;
  const PhoneSetupSection({super.key, required this.device});

  /// The server's `GRANT_KEYS`, verbatim (`packages/shared-types/src/capabilities.ts`).
  ///
  /// Kept here so a test can compare the two lists: a grant added to the shared vocabulary without a label
  /// below would otherwise reach a parent as `• full_screen_intent` in the "what to fix" list.
  static const grantKeys = [
    'accessibility',
    'usage_access',
    'overlay',
    'device_admin',
    'web_filter',
    'location',
    'private_dns',
    'battery',
    'usb_debugging',
    'notification_listener',
    'full_screen_intent',
    'family_controls',
    'background_refresh',
  ];

  /// The order the ADR lists features in; anything else the phone reports is appended after them.
  static const featureOrder = [
    'lock_screen',
    'pause_screen',
    'app_blocking',
    'screen_time',
    'web_filter',
    'pause_internet',
    'location',
    'uninstall_guard',
    'notification_scan',
    'call_sms_log',
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // `setup` is never null from a current server: it answers with the projection and puts
    // `reportedAt: null` inside it when the phone has never reported (issue #601). Reading only the
    // object made every device look reported; reading only the timestamp is the one honest test.
    final setup = device.hasCapabilityReport ? device.setup : null;
    if (setup == null) {
      // Every agent older than this report, and every phone before its first upload. "We do not know yet",
      // never "nothing works".
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
        child: Text(l10n.phoneSetupNeverReported, style: Theme.of(context).textTheme.bodySmall),
      );
    }

    final age = formatLastSeen(context, setup.reportedAt);
    final features = [
      ...featureOrder.where(setup.features.containsKey),
      ...setup.features.keys.where((k) =>
          !featureOrder.contains(k) && k != DeviceSetup.accountAdminKey),
    ];

    return Padding(
      key: const ValueKey('phoneSetupSection'),
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, 0, AppSpace.lg, AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.phoneSetupTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.xxs),
          Text(
            setup.stale ? l10n.phoneSetupStale(age) : l10n.phoneSetupReported(age),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // ADR-0041 D5.5: the computer's own report that the child's account is an administrator. Only
          // when the report says so — an absent key is "not said", which is not "weak".
          if (setup.childAccountIsAdministrator) ...[
            const SizedBox(height: AppSpace.xs),
            _line(context, Icons.admin_panel_settings_outlined,
                context.tokens.warn, l10n.computerAdminWarning,
                key: const ValueKey('computerAdminWarning')),
          ],
          const SizedBox(height: AppSpace.xs),
          // The "what to fix" list first: it is the only part a parent can act on.
          if (setup.missing.isEmpty)
            _line(context, Icons.check_circle_outline, context.tokens.ok, l10n.phoneSetupNothingMissing)
          else ...[
            _line(context, Icons.priority_high, context.tokens.warn, l10n.phoneSetupFixList),
            for (final grant in setup.missing)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: AppSpace.lg, top: AppSpace.xxs),
                child: Text('• ${_grantLabel(l10n, grant)}', style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
          if (features.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xxs,
              children: [for (final f in features) _featureChip(context, l10n, f, setup.features[f]!)],
            ),
          ],
          // osra-security#6 item 2: another space is not a fault by itself, but it is where OSRA cannot see.
          for (final kind in _profileKinds(setup.profiles))
            Padding(
              padding: const EdgeInsetsDirectional.only(top: AppSpace.xxs),
              child: _line(context, Icons.layers_outlined, context.tokens.warn, _profileText(l10n, kind)),
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, Color color, String text, {Key? key}) => Row(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpace.xxs),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      );

  Widget _featureChip(BuildContext context, AppLocalizations l10n, String key, String state) {
    final (icon, color) = switch (state) {
      'ready' => (Icons.check_circle, context.tokens.ok),
      'degraded' => (Icons.error_outline, context.tokens.warn),
      'not_supported' => (Icons.block, Theme.of(context).disabledColor),
      _ => (Icons.cancel_outlined, context.tokens.danger),
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(icon, size: 14, color: color),
      label: Text('${_featureLabel(l10n, key)} · ${_stateLabel(l10n, state)}'),
    );
  }

  /// The three kinds `PROFILE_KINDS` has, deduped and in a stable order, skipping `others == 0`.
  List<String> _profileKinds(DeviceProfiles? profiles) {
    if (profiles == null || profiles.others < 1) return const [];
    const order = ['clone', 'work', 'secure_folder', 'other'];
    final known = order.where(profiles.kinds.contains).toList();
    // `others >= 1` with no kind we can name — an empty `kinds`, or a kind added after this build — is still
    // another space, and saying nothing would read as "nothing to see" (#552 review, point 2).
    return known.isEmpty ? const ['other'] : known;
  }

  String _profileText(AppLocalizations l10n, String kind) => switch (kind) {
        'clone' => l10n.phoneSetupOtherSpaceClone,
        'work' => l10n.phoneSetupOtherSpaceWork,
        _ => l10n.phoneSetupOtherSpaceOther,
      };

  String _featureLabel(AppLocalizations l10n, String key) => switch (key) {
        'lock_screen' => l10n.phoneSetupFeatureLockScreen,
        'pause_screen' => l10n.phoneSetupFeaturePauseScreen,
        'app_blocking' => l10n.phoneSetupFeatureAppBlocking,
        'screen_time' => l10n.phoneSetupFeatureScreenTime,
        'web_filter' => l10n.phoneSetupFeatureWebFilter,
        'pause_internet' => l10n.phoneSetupFeaturePauseInternet,
        'location' => l10n.phoneSetupFeatureLocation,
        'uninstall_guard' => l10n.phoneSetupFeatureUninstallGuard,
        'notification_scan' => l10n.phoneSetupFeatureNotificationScan,
        'call_sms_log' => l10n.phoneSetupFeatureCallSmsLog,
        // A newer agent naming a feature this build of the app does not know: show the wire key rather than
        // dropping the row, so the parent sees that something is reported.
        _ => key,
      };

  String _stateLabel(AppLocalizations l10n, String state) => switch (state) {
        'ready' => l10n.phoneSetupStateReady,
        'degraded' => l10n.phoneSetupStateDegraded,
        'not_supported' => l10n.phoneSetupStateNotSupported,
        _ => l10n.phoneSetupStateUnavailable,
      };

  String _grantLabel(AppLocalizations l10n, String key) => switch (key) {
        'accessibility' => l10n.grantAccessibility,
        'usage_access' => l10n.grantUsageAccess,
        'overlay' => l10n.grantOverlay,
        'device_admin' => l10n.grantDeviceAdmin,
        'web_filter' => l10n.grantWebFilter,
        'location' => l10n.grantLocation,
        'private_dns' => l10n.grantPrivateDns,
        'battery' => l10n.grantBattery,
        'usb_debugging' => l10n.grantUsbDebugging,
        'notification_listener' => l10n.grantNotificationListener,
        'full_screen_intent' => l10n.grantFullScreenIntent,
        'family_controls' => l10n.grantFamilyControls,
        'background_refresh' => l10n.grantBackgroundRefresh,
        _ => key,
      };
}
