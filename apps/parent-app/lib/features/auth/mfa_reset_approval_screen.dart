import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/mfa_reset_api.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../theme/app_tokens.dart';
import 'mfa_reset_messages.dart';

/// Step 3b of ADR-0031: another `owner` or `co-parent` approves — or declines —
/// from their own signed-in app. A `guardian` cannot; the API answers
/// `403 role_not_allowed` and this screen says so in words.
///
/// **Known API gap:** the route takes only `{requestId}` and returns no details
/// about the request, so this screen cannot name the parent who asked, their
/// address, or when the request was made — and no notification carries the
/// request id here yet (ADR-0031 decision 4's templates are unbuilt). The copy
/// therefore says "another parent in your family", not a name; the screen is
/// reached with a request id from outside the app today.
class MfaResetApprovalScreen extends ConsumerStatefulWidget {
  const MfaResetApprovalScreen({super.key, required this.requestId});

  final String requestId;

  @override
  ConsumerState<MfaResetApprovalScreen> createState() => _MfaResetApprovalScreenState();
}

class _MfaResetApprovalScreenState extends ConsumerState<MfaResetApprovalScreen> {
  bool _busy = false;
  MfaResetFailure? _failure;
  DateTime? _windowEndsAt;
  bool _declined = false;

  bool get _answered => _windowEndsAt != null || _declined;

  bool get _terminal => _failure != null &&
      const {
        MfaResetFailureKind.requestNotOpen,
        MfaResetFailureKind.requestCancelled,
        MfaResetFailureKind.requestExpired,
        MfaResetFailureKind.requestCompleted,
        MfaResetFailureKind.requestNotFound,
        MfaResetFailureKind.roleNotAllowed,
        MfaResetFailureKind.forbidden,
        MfaResetFailureKind.unauthorized,
      }.contains(_failure!.kind);

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final accepted = await ref.read(mfaResetApiProvider).approve(widget.requestId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _windowEndsAt = accepted.windowEndsAt;
      });
    } on MfaResetFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = failure;
      });
    }
  }

  Future<void> _decline() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.mfaResetDeclineTitle),
        content: Text(dialogContext.l10n.mfaResetDeclineBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.mfaResetCancelKeep),
          ),
          FilledButton(
            key: const ValueKey('mfaResetDeclineConfirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.mfaResetDeclineConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref.read(mfaResetApiProvider).cancel(requestId: widget.requestId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _declined = true;
      });
    } on MfaResetFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final missingId = widget.requestId.isEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaResetApproveTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            if (missingId)
              Text(
                l10n.mfaResetApproveNeedsId,
                key: const ValueKey('mfaResetApproveMissingId'),
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text(l10n.mfaResetApproveIntro, style: theme.textTheme.bodyMedium),
              if (_windowEndsAt != null) ...[
                const SizedBox(height: AppSpace.lg),
                Text(
                  l10n.mfaResetApproved,
                  key: const ValueKey('mfaResetApproved'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.ok),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  l10n.mfaResetWindowEndsAt(_format(context, _windowEndsAt!)),
                  key: const ValueKey('mfaResetApprovedWindow'),
                  style: theme.textTheme.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
                ),
              ],
              if (_declined) ...[
                const SizedBox(height: AppSpace.lg),
                Text(
                  l10n.mfaResetDeclined,
                  key: const ValueKey('mfaResetDeclined'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.ok),
                ),
              ],
              if (_failure != null) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  mfaResetFailureText(l10n, _failure!.kind),
                  key: const ValueKey('mfaResetApproveError'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
                ),
              ],
              if (!_answered) ...[
                const SizedBox(height: AppSpace.xl),
                FilledButton.icon(
                  key: const ValueKey('mfaResetApprove'),
                  onPressed: _busy || _terminal ? null : _approve,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.verified_user_outlined),
                  label: Text(l10n.mfaResetApproveAction),
                ),
                const SizedBox(height: AppSpace.md),
                OutlinedButton.icon(
                  key: const ValueKey('mfaResetDecline'),
                  onPressed: _busy || _terminal ? null : _decline,
                  icon: const Icon(Icons.block),
                  label: Text(l10n.mfaResetDeclineAction),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _format(BuildContext context, DateTime at) =>
      DateFormat.yMMMd(context.localeName).add_Hm().format(at.toLocal());
}
