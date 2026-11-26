import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/permission_errors.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// Feature switch for UX Final Decisions **P-22 Settings** (#1179).
///
/// Enable with `--dart-define=OSRA_UX_P22=true`, or override [p22SettingsEnabledProvider] in tests. When it is
/// false nothing routes to this screen, so the app keeps the settings entries it shipped with.
const bool kEnableUxP22Settings = bool.fromEnvironment('OSRA_UX_P22', defaultValue: false);

final p22SettingsEnabledProvider = Provider<bool>((ref) => kEnableUxP22Settings);

/// P-22 (`#1179`, Bureau row): a plain grouped list with the current value on every row — language and
/// appearance on top, then security, then the account. No score, no tiles, no travel mode, and **no Parent PIN
/// row** (Fix 4: the phone lock is the only app-level unlock).
///
/// Every label here is either an approved key that already existed (`languageLabel`, `appearanceTitle`,
/// `mfaSettingsTitle`, `mfaRecoveryCodesTitle`, `deleteAccountTitle`) or one of the six the Arabic Language
/// Bureau signed for this screen at 20:11 UAE.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _signingOutAll = false;

  Future<void> _signOut() async {
    await ref.read(authProvider.notifier).logout();
  }

  /// `/v1/auth/logout-all` revokes every refresh token of this parent, this device included; the app then signs
  /// itself out the same way the single-device row does.
  Future<void> _signOutEverywhere() async {
    if (_signingOutAll) return;
    final l10n = context.l10n;
    setState(() => _signingOutAll = true);
    try {
      await ref.read(apiClientProvider).raw.post('/v1/auth/logout-all');
      await ref.read(authProvider.notifier).logout();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _signingOutAll = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyErrorText(l10n, e, () => l10n.saveFailed)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final overview = ref.watch(familyProvider).valueOrNull;
    final twoStepOn = overview?.parent.mfaEnabled ?? false;

    Widget row({
      required Key key,
      required String label,
      String? value,
      IconData icon = Icons.chevron_right,
      VoidCallback? onTap,
    }) =>
        ListTile(
          key: key,
          minVerticalPadding: AppSpace.md,
          leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          title: Text(label),
          trailing: Text(
            value ?? '',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          onTap: onTap,
        );

    Widget group(String heading, List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.xs),
              child: Text(heading, style: theme.textTheme.titleSmall),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: Column(children: children),
            ),
          ],
        );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('settingsList'),
          padding: const EdgeInsets.only(bottom: AppSpace.xl),
          children: [
            group(l10n.settingsGroupLanguage, [
              row(
                key: const ValueKey('settingsRow-language'),
                label: l10n.languageLabel,
                icon: Icons.translate,
                onTap: () => context.push('/settings/appearance'),
              ),
              row(
                key: const ValueKey('settingsRow-appearance'),
                label: l10n.appearanceTitle,
                icon: Icons.palette_outlined,
                onTap: () => context.push('/settings/appearance'),
              ),
            ]),
            group(l10n.settingsGroupSecurity, [
              row(
                key: const ValueKey('settingsRow-twoStep'),
                label: l10n.mfaSettingsTitle,
                value: twoStepOn ? l10n.settingsValueOn : l10n.settingsValueOff,
                icon: Icons.verified_user_outlined,
                onTap: () => context.push('/settings/mfa'),
              ),
              if (twoStepOn)
                row(
                  key: const ValueKey('settingsRow-recoveryCodes'),
                  label: l10n.mfaRecoveryCodesTitle,
                  icon: Icons.key_outlined,
                  onTap: () => context.push('/settings/mfa'),
                ),
            ]),
            group(l10n.settingsGroupAccount, [
              row(
                key: const ValueKey('settingsRow-signOut'),
                label: l10n.settingsSignOut,
                icon: Icons.logout,
                onTap: _signOut,
              ),
              row(
                key: const ValueKey('settingsRow-signOutAll'),
                label: l10n.settingsSignOutAll,
                icon: Icons.devices_other,
                onTap: _signingOutAll ? null : _signOutEverywhere,
              ),
              row(
                key: const ValueKey('settingsRow-deleteAccount'),
                label: l10n.deleteAccountTitle,
                icon: Icons.delete_outline,
                onTap: () => context.push('/settings/delete-account'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
