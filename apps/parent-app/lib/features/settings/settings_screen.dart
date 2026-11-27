import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_tokens.dart';

/// Feature switch for UX Final Decisions **P-22 Settings** (#1179).
///
/// Enable with `--dart-define=OSRA_UX_P22=true` (or `OSRA_UX_FINAL=true`), or override [p22SettingsEnabledProvider] in tests. When it is
/// false nothing routes to this screen, so the app keeps the settings entries it shipped with.
const bool kEnableUxP22Settings = bool.fromEnvironment(
  'OSRA_UX_P22',
  defaultValue: bool.fromEnvironment('OSRA_UX_FINAL', defaultValue: false),
);

final p22SettingsEnabledProvider = Provider<bool>((ref) => kEnableUxP22Settings);

/// P-22 (`#1179`, Bureau row): a plain grouped list with the current value on every row — language and
/// appearance on top, then security, then the account. No score, no tiles, no travel mode, and **no Parent PIN
/// row** (Fix 4: the phone lock is the only app-level unlock).
///
/// Every label here is either an approved key that already existed (`languageLabel`, `appearanceTitle`,
/// `mfaSettingsTitle`, `mfaRecoveryCodesTitle`, `deleteAccountTitle`) or one of the six the Arabic Language
/// Bureau signed for this screen at 20:11 UAE.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: const SafeArea(child: SettingsP22Body()),
    );
  }
}

/// P-22 grouped Settings list body, shared by [SettingsScreen] (`/settings`) and
/// the P-07 Home Settings tab (U103) so switching to Settings never requires a
/// second "Settings → Settings" tap.
class SettingsP22Body extends ConsumerStatefulWidget {
  final VoidCallback? onSignOut;
  final bool includePrivacyRow;

  const SettingsP22Body({
    super.key,
    this.onSignOut,
    this.includePrivacyRow = false,
  });

  @override
  ConsumerState<SettingsP22Body> createState() => _SettingsP22BodyState();
}

class _SettingsP22BodyState extends ConsumerState<SettingsP22Body> {
  bool _signingOutAll = false;

  Future<void> _signOut() async {
    final override = widget.onSignOut;
    if (override != null) {
      override();
      return;
    }
    await ref.read(authProvider.notifier).logout();
  }

  /// `/v1/auth/logout-all` revokes every refresh token of this parent, this device included; the app then signs
  /// itself out the same way the single-device row does. The confirm step comes first and Cancel is the default,
  /// because this row is one tap from signing out every phone the account uses (UI/UX Bureau, 22:12 UAE).
  Future<void> _signOutEverywhere() async {
    if (_signingOutAll) return;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('settingsSignOutAllDialog'),
        title: Text(l10n.settingsSignOutAllTitle),
        content: Text(l10n.settingsSignOutAllBody),
        actions: [
          TextButton(
            key: const ValueKey('settingsSignOutAllCancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const ValueKey('settingsSignOutAllConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(l10n.settingsSignOutAllConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _signingOutAll = true);
    // osra-security#92: the notifier keeps the ordering — push removal first, then the account-wide
    // revocation, then local clear — because the removal authenticates with the session being revoked.
    // A failed revocation leaves the phone signed in, so it can be retried (Claude, 11:36).
    try {
      await ref.read(authProvider.notifier).logoutEverywhere();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _signingOutAll = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyErrorText(l10n, e, () => l10n.saveFailed)),
      ));
    }
  }

  /// B1 (UI/UX Bureau, 00:53): the current language and theme, from the appearance screen's own labels.
  String _languageValue(AppLocalizations l10n, Locale? locale) => switch (locale?.languageCode) {
        'ar' => l10n.arabic,
        'en' => l10n.english,
        _ => l10n.system,
      };

  String _themeValue(AppLocalizations l10n, ThemeMode mode) => switch (mode) {
        ThemeMode.light => l10n.light,
        ThemeMode.dark => l10n.dark,
        ThemeMode.system => l10n.system,
      };

  /// A21: the family's offset in words, never a raw IANA id and never a raw number. The catalog's city is
  /// not reachable from the family snapshot (it carries , not the zone id), so this is the
  /// offset alone — which the Bureau allows.
  String _utcOffsetLabel(AppLocalizations l10n) {
    final minutes = ref.watch(familyProvider).valueOrNull?.family.utcOffsetMinutes;
    // B2 (Arabic and UI/UX Bureaus, 00:53): a time zone is never 'off'. No clock means no value.
    if (minutes == null) return '';
    final sign = minutes < 0 ? '-' : '+' ;
    final abs = minutes.abs();
    final hh = abs ~/ 60;
    final mm = abs % 60;
    final offset = mm == 0 ? 'UTC$sign$hh' : 'UTC$sign${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
    return ltrIsolate(offset);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final overview = ref.watch(familyProvider).valueOrNull;
    final twoStepOn = overview?.parent.mfaEnabled ?? false;

    // A21: every row carries its current value on the trailing side and wraps under the label at 320 px /
    // 200 %, so a long value never truncates the label it belongs to.
    Widget row({
      required Key key,
      required String label,
      String? value,
      IconData icon = Icons.chevron_right,
      VoidCallback? onTap,
      bool danger = false,
    }) =>
        LayoutBuilder(
          builder: (context, constraints) {
            // The spec is about the screen, not the row: at 390 px the value sits on the trailing side,
            // at 320 px (or once the text is scaled) it wraps under its label. A row inside a card is
            // ~60 px narrower than the screen, so measuring the row here would wrap at 390 too.
            final screenWidth = MediaQuery.sizeOf(context).width;
            final narrow = screenWidth < 360 || MediaQuery.textScalerOf(context).scale(14) > 16;
            final valueStyle =
                theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
            final titleStyle = danger
                ? theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.error)
                : null;
            return ListTile(
              key: key,
              minVerticalPadding: AppSpace.md,
              leading: Icon(icon,
                  color: danger ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant),
              title: Text(label, style: titleStyle),
              subtitle: narrow && value != null ? Text(value, style: valueStyle) : null,
              trailing: narrow ? null : Text(value ?? '', style: valueStyle),
              onTap: onTap,
            );
          },
        );

    /// Read-only row (A21's time zone until #1211): a plain tile with no chevron and no ripple, because
    /// there is nothing to open yet and a tappable-looking row that does nothing is worse than a label.
    Widget readOnlyRow({required Key key, required String label, required String value, required IconData icon}) =>
        ListTile(
          key: key,
          minVerticalPadding: AppSpace.md,
          // No onTap: no ripple, no chevron, and normal colours — a disabled tile would dim the label
          // and read as broken rather than as read-only.
          leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          title: Text(label),
          trailing: value.isEmpty
              ? null
              : Text(value,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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

    // P-22 / Karim's pick: the security check sits on top and shows only while something is unfinished.
    // With no "codes saved" flag to read, the only item it can honestly carry is two-step verification.
    final securityCard = twoStepOn
        ? null
        : Card(
            key: const ValueKey('settingsSecurityCard'),
            margin: const EdgeInsetsDirectional.fromSTEB(AppSpace.lg, AppSpace.sm, AppSpace.lg, 0),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.settingsSecurityCardTitle, style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpace.xs),
                  Text(l10n.settingsSecurityCardLine, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton(
                      key: const ValueKey('settingsSecurityCardButton'),
                      onPressed: () => context.push('/settings/mfa'),
                      child: Text(l10n.settingsSecurityCardButton),
                    ),
                  ),
                ],
              ),
            ),
          );

    return ListView(
      key: const ValueKey('settingsList'),
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      children: [
        if (securityCard != null) securityCard,
        group(l10n.settingsGroupLanguage, [
          row(
            key: const ValueKey('settingsRow-language'),
            label: l10n.languageLabel,
            icon: Icons.translate,
            value: _languageValue(l10n, ref.watch(localeProvider)),
            onTap: () => context.push('/settings/appearance'),
          ),
          row(
            key: const ValueKey('settingsRow-appearance'),
            label: l10n.appearanceTitle,
            icon: Icons.palette_outlined,
            value: _themeValue(l10n, ref.watch(themeModeProvider)),
            onTap: () => context.push('/settings/appearance'),
          ),
          readOnlyRow(
            key: const ValueKey('settingsRow-timeZone'),
            label: l10n.settingsTimeZone,
            icon: Icons.public,
            value: _utcOffsetLabel(l10n),
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
            key: const ValueKey('settingsRow-digest'),
            label: l10n.digestPrefsTitle,
            icon: Icons.mail_outline,
            onTap: () => context.push('/settings/digests'),
          ),
          if (widget.includePrivacyRow)
            row(
              key: const ValueKey('homeSettingsPrivacy'),
              label: l10n.privacyMenu,
              icon: Icons.privacy_tip_outlined,
              onTap: () => context.push('/settings/privacy'),
            ),
          // Delete account is last in Account and in the error colour (A21 rule).
          row(
            key: const ValueKey('settingsRow-deleteAccount'),
            label: l10n.deleteAccountTitle,
            icon: Icons.delete_outline,
            danger: true,
            onTap: () => context.push('/settings/delete-account'),
          ),
        ]),
      ],
    );
  }
}
