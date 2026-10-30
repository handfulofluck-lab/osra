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

  /// The account the deletion applies to, from the same overview that gives the role — one source for
  /// both, so the email the parent is asked to type is the email the server holds.
  String get _email => ref.read(familyProvider).valueOrNull?.parent.email ?? '';

  /// Normalised on both sides, as `/login` and #467 are: `Karim@…` against `karim@…` must not leave the
  /// button dead (#442 PR 2 review).
  bool get _matches {
    final email = _email.trim().toLowerCase();
    return email.isNotEmpty && _confirm.text.trim().toLowerCase() == email;
  }

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
      // The navigation is guarded on purpose — a failure to route must not be reported as "the account
      // was not deleted", which is what fell through to the generic catch before (#469 review).
      await ref.read(authProvider.notifier).logout();
      ref.invalidate(familyProvider);
      if (mounted) {
        try {
          context.go('/login');
        } catch (_) {
          // Deliberately swallowed: a screen that cannot route must not report the deletion as failed.
        }
      }
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
    final family = ref.watch(familyProvider);
    final overview = family.valueOrNull;
    final parent = overview?.parent;
    final scope = parent == null ? null : deleteScopeFor(parent);
    final isOwner = scope == DeleteScope.family;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.deleteAccountTitle)),
      body: OverviewNotLoaded(
        overview: overview,
        error: family.hasError ? '${family.error}' : null,
        onRetry: () => ref.invalidate(familyProvider),
        child: ListView(
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

/// A `null` overview is "not loaded yet", not "no account": showing either copy while the role is
/// unknown would offer the wrong deletion, so this never falls back to one.
///
/// And it does not spin forever: `GET /v1/family/me` failing leaves the role unknown, which is exactly
/// the state where guessing is wrong — so the error is shown with a Retry instead (#442 PR 2 review).
class OverviewNotLoaded extends StatelessWidget {
  const OverviewNotLoaded({
    super.key,
    required this.overview,
    required this.child,
    this.error,
    this.onRetry,
  });

  final FamilyOverview? overview;
  final Widget child;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (overview != null) return child;
    if (error != null && onRetry != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 32),
              const SizedBox(height: AppSpace.sm),
              Text(context.l10n.deleteAccountLoadFailed, textAlign: TextAlign.center),
              const SizedBox(height: AppSpace.xs),
              Text(error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppSpace.md),
              OutlinedButton(
                key: const ValueKey('deleteAccountRetry'),
                onPressed: onRetry,
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
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
