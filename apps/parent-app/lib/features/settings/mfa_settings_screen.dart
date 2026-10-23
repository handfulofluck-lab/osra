import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/mfa_api.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../theme/app_tokens.dart';
import '../auth/mfa_reset_approval_screen.dart';
import '../auth/mfa_reset_messages.dart';
import '../auth/mfa_reset_request_screen.dart';
import 'mfa_enroll_screen.dart';
import 'mfa_messages.dart';
import 'reauth_dialog.dart';
import 'recovery_codes_screen.dart';

/// Settings home for the second factor (roadmap 3.3): status, enrolment, and
/// the only route to a recovery-code batch.
///
/// [mfaEnabledOverride] is a test seam; in the app the status comes from the
/// signed-in parent.
class MfaSettingsScreen extends ConsumerStatefulWidget {
  const MfaSettingsScreen({super.key, this.mfaEnabledOverride});

  final bool? mfaEnabledOverride;

  @override
  ConsumerState<MfaSettingsScreen> createState() => _MfaSettingsScreenState();
}

class _MfaSettingsScreenState extends ConsumerState<MfaSettingsScreen> {
  bool _busy = false;
  MfaFailureKind? _error;
  bool _noCodes = false;

  Future<void> _openEnrollment() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => const MfaEnrollScreen(),
    ));
  }

  Future<void> _regenerate() async {
    final proof = await showReauthDialog(context);
    if (proof == null) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _noCodes = false;
    });
    try {
      final batch = await ref.read(mfaApiProvider).regenerate(
            password: proof.password,
            code: proof.code,
          );
      if (!mounted) return;
      if (batch.isEmpty) {
        setState(() {
          _busy = false;
          _noCodes = true;
        });
        return;
      }
      setState(() => _busy = false);
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => RecoveryCodesScreen(batch: batch),
      ));
    } on MfaFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.kind;
      });
    }
  }

  String _requesterRole(AppLocalizations l10n, MfaResetPendingRequest request) {
    final role = mfaResetRoleName(l10n, request.requesterRole);
    if (role.isEmpty) return l10n.mfaResetRoleFamilyMember;
    if (request.state == 'witness_passed') return l10n.mfaResetPendingAlreadyWaiting(role);
    return role;
  }

  void _openApproval(MfaResetPendingRequest request) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MfaResetApprovalScreen(
        requestId: request.requestId,
        requesterName: request.requesterName,
        requesterRole: request.requesterRole,
        pendingState: request.state,
        pendingWindowEndsAt: request.windowEndsAt,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final bool enabled = widget.mfaEnabledOverride ??
        ref.watch(authProvider.select<bool>((state) => state.parent?.mfaEnabled ?? false));
    // The settings entry is the second place a signed-in owner/co-parent can
    // learn that a reset needs their witness. A guardian's 403 is an empty
    // list, not an error (see mfaResetPendingProvider).
    final pendingResets = ref.watch(mfaResetPendingProvider).valueOrNull ?? const <MfaResetPendingRequest>[];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaSettingsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  enabled ? Icons.verified_user : Icons.gpp_maybe_outlined,
                  color: enabled ? context.tokens.ok : context.tokens.warn,
                ),
                title: Text(enabled ? l10n.mfaStatusOn : l10n.mfaStatusOff),
                subtitle: Text(enabled ? l10n.mfaSettingsStatusOn : l10n.mfaSettingsStatusOff),
              ),
            ),
            if (pendingResets.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xl),
              Text(
                l10n.mfaResetPendingSectionTitle,
                key: const ValueKey('mfaResetPendingSection'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.xs),
              Card(
                child: Column(
                  children: [
                    for (final request in pendingResets)
                      ListTile(
                        key: ValueKey('mfaResetPendingItem-${request.requestId}'),
                        leading: const Icon(Icons.lock_reset),
                        title: Text(request.requesterName.trim().isEmpty
                            ? l10n.mfaResetRoleFamilyMember
                            : request.requesterName),
                        subtitle: Text(_requesterRole(l10n, request)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy ? null : () => _openApproval(request),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Text(l10n.mfaSettingsExplanation, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.lg),
            FilledButton.icon(
              key: const ValueKey('mfaSetupButton'),
              onPressed: _busy ? null : _openEnrollment,
              icon: const Icon(Icons.qr_code_2),
              label: Text(enabled ? l10n.mfaReplaceAuthenticator : l10n.mfaSetupAuthenticator),
            ),
            const SizedBox(height: AppSpace.xl),
            Text(l10n.mfaRecoveryCodesTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.xs),
            Text(l10n.mfaRecoveryCodesExplanation, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.xs),
            // ADR-0031 decision 6: what is left when both the authenticator and
            // every code are gone, stated beside the codes themselves.
            Text(
              l10n.mfaResetSetupNote,
              key: const ValueKey('mfaResetSetupNote'),
              style: theme.textTheme.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.md),
            if (_error != null) ...[
              Text(
                mfaFailureText(l10n, _error!),
                key: const ValueKey('mfaSettingsError'),
                style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
              ),
              const SizedBox(height: AppSpace.md),
            ],
            if (_noCodes) ...[
              Text(
                l10n.mfaNoRecoveryCodes,
                key: const ValueKey('mfaSettingsNoCodes'),
                style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
              ),
              const SizedBox(height: AppSpace.md),
            ],
            OutlinedButton.icon(
              key: const ValueKey('mfaRegenerateButton'),
              onPressed: _busy ? null : _regenerate,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.key),
              label: Text(l10n.mfaRegenerateCodes),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              l10n.mfaRegenerateWarning,
              style: theme.textTheme.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.lg),
            // ADR-0031: the route back when both the authenticator and every
            // code are gone. Kept apart from the codes section because it does
            // not touch them.
            OutlinedButton.icon(
              key: const ValueKey('mfaResetEntry'),
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push<void>(MaterialPageRoute(
                        builder: (_) => const MfaResetRequestScreen(),
                      )),
              icon: const Icon(Icons.lock_reset),
              label: Text(l10n.mfaResetSettingsEntry),
            ),
          ],
        ),
      ),
    );
  }
}
