import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart' show apiClientProvider, authProvider;
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'reauth_dialog.dart';

/// What the two deletions mean, so the sentence the parent reads is the sentence that happens.
///
/// The owner's request removes **the whole family** — every child, every device and every other
/// parent — through `DELETE /v1/family`. Anyone else removes **only their own account** through
/// `DELETE /v1/me`, and the family carries on without them. Both routes already exist (#464); this
/// screen is the only thing that was missing, and Play requires it to be reachable in the app.
enum DeleteScope { family, self }

/// The scope for this parent, or null while the overview has not loaded.
///
/// `owner` is the only role that can delete the family; the API answers `owner_role_required` or
/// `owner_must_delete_family` for the other direction, so deciding here keeps a parent from being
/// shown an action that can only fail.
DeleteScope? deleteScopeFor(Parent overviewParent) =>
    overviewParent.role == 'owner' ? DeleteScope.family : DeleteScope.self;

/// Roadmap 5.2 / #442 PR 2: the in-app half of account deletion.
///
/// Deliberately slow, like the consent withdrawal: the copy states what stops and what is deleted, and
/// the button stays disabled until the parent types their own email. Deletion has no undo, and an
/// "undo" would mean keeping a child's data we told the parent we had deleted.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  String get _email => ref.read(authProvider).parent?.email ?? '';

  bool get _matches => _email.isNotEmpty && _confirm.text.trim().toLowerCase() == _email.toLowerCase();

  Future<void> _submit(DeleteScope scope) async {
    if (_busy || !_matches) return;
    final l10n = context.l10n;
    final proof = await showReauthDialog(context);
    if (proof == null || !mounted) return;
    // `#464`'s ReauthSchema takes `password` (required) and an optional `mfaCode`; the shared dialog
    // allows a code alone for other calls, so the password is required here rather than letting the
    // server answer a 401 the parent cannot read as "you left the password blank".
    if (proof.password.trim().isEmpty) {
      setState(() => _error = l10n.deleteAccountPasswordRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).raw.delete(
            scope == DeleteScope.family ? '/v1/family' : '/v1/me',
            data: {
              'password': proof.password,
              if (proof.code.trim().isNotEmpty) 'mfaCode': proof.code.trim(),
            },
          );
      // The account the token belongs to is gone: drop the local session and go back to sign-in.
      await ref.read(authProvider.notifier).logout();
      ref.invalidate(familyProvider);
      if (mounted) context.go('/login');
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = deleteAccountError(l10n, e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.deleteAccountFailed('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final overview = ref.watch(familyProvider).valueOrNull;
    final parent = overview?.parent;
    final scope = parent == null ? null : deleteScopeFor(parent);
    final isOwner = scope == DeleteScope.family;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.deleteAccountTitle)),
      body: OverviewNotLoaded(overview: overview, child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Card(
            color: context.tokens.surfaceVariant,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: context.tokens.danger),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      isOwner ? l10n.deleteAccountFamilyWarning : l10n.deleteAccountSelfWarning,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          _SectionTitle(isOwner ? l10n.deleteAccountFamilyStopsTitle : l10n.deleteAccountSelfStopsTitle),
          for (final line in isOwner ? _familyStops(l10n) : _selfStops(l10n)) _Bullet(line),
          const SizedBox(height: AppSpace.lg),
          TextField(
            key: const ValueKey('deleteAccountConfirm'),
            controller: _confirm,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.deleteAccountTypeEmail(_email),
              helperText: l10n.deleteAccountTypeHint,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              _error!,
              key: const ValueKey('deleteAccountError'),
              style: TextStyle(color: context.tokens.danger),
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          FilledButton(
            key: const ValueKey('deleteAccountSubmit'),
            style: FilledButton.styleFrom(
              backgroundColor: context.tokens.danger,
              foregroundColor: context.tokens.onDanger,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: (_busy || !_matches || scope == null) ? null : () => _submit(scope),
            child: Text(_busy ? l10n.deleteAccountBusy : l10n.deleteAccountSubmit),
          ),
          const SizedBox(height: AppSpace.xs),
          TextButton(
            key: const ValueKey('deleteAccountCancel'),
            onPressed: _busy ? null : () => context.pop(),
            child: Text(l10n.cancel),
          ),
        ],
      )),
    );
  }
}

List<String> _familyStops(AppLocalizations l10n) => [
      l10n.deleteAccountFamilyStopsData,
      l10n.deleteAccountFamilyStopsDevices,
      l10n.deleteAccountFamilyStopsParents,
    ];

List<String> _selfStops(AppLocalizations l10n) => [
      l10n.deleteAccountSelfStopsAccount,
      l10n.deleteAccountSelfStopsFamilyKept,
    ];

/// The one sentence for a refusal, so a `409` or a `428` never reaches the parent as a code.
String deleteAccountError(AppLocalizations l10n, DioException e) {
  final status = e.response?.statusCode;
  final body = e.response?.data;
  final code = body is Map ? body['error'] : null;
  return switch (code) {
    'reauth_failed' => l10n.deleteAccountReauthFailed,
    'mfa_reenroll_required' => l10n.deleteAccountMfaReenroll,
    'consent_records_held' => l10n.deleteAccountConsentHeld,
    'owner_role_required' => l10n.deleteAccountOnlyOwner,
    'owner_must_delete_family' => l10n.deleteAccountOwnerMustUseFamily,
    _ => l10n.deleteAccountFailed('${status ?? '?'}: ${code ?? e.message ?? ''}'),
  };
}

/// A `null` overview is "not loaded yet", not "no account": showing the family copy while the role is
/// unknown would offer the wrong deletion.
class OverviewNotLoaded extends StatelessWidget {
  const OverviewNotLoaded({super.key, required this.overview, required this.child});

  final FamilyOverview? overview;
  final Widget child;

  @override
  Widget build(BuildContext context) => overview == null
      ? const Center(child: CircularProgressIndicator())
      : child;
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.xs),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.only(bottom: AppSpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xxs),
              child: Icon(Icons.circle, size: 6, color: context.tokens.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}
