import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/mfa_reset_api.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../theme/app_tokens.dart';
import 'mfa_reset_messages.dart';

/// Step 3b of ADR-0031: another `owner` or `co-parent` approves — or declines —
/// from their own signed-in app. A `guardian` cannot; the API answers
/// `403 role_not_allowed` and this screen says so in words.
///
/// [requesterName], [requesterRole], [pendingState] and [pendingWindowEndsAt]
/// come from `GET /v1/auth/mfa/reset/pending`: the dashboard and the MFA
/// settings screen open this prompt straight from that list, with the id and
/// the name the route returned. The deep link (`/mfa/reset/approve?requestId=`)
/// reaches the prompt through [MfaResetApprovalLink], which takes only the id
/// from the URL and looks the rest up in that same list.
/// Without a name the copy falls back to "another parent in your family",
/// which is what the app said before the list existed.
///
/// [pendingState] `witness_passed` means someone already supplied the witness:
/// the prompt then shows the running window and offers only decline (a cancel
/// during the window), instead of an Approve button the API would refuse.
class MfaResetApprovalScreen extends ConsumerStatefulWidget {
  const MfaResetApprovalScreen({
    super.key,
    required this.requestId,
    this.requesterName,
    this.requesterRole,
    this.pendingState,
    this.pendingWindowEndsAt,
  });

  final String requestId;
  final String? requesterName;
  final String? requesterRole;
  final String? pendingState;
  final DateTime? pendingWindowEndsAt;

  @override
  ConsumerState<MfaResetApprovalScreen> createState() => _MfaResetApprovalScreenState();
}

class _MfaResetApprovalScreenState extends ConsumerState<MfaResetApprovalScreen> {
  bool _busy = false;
  MfaResetFailure? _failure;
  DateTime? _windowEndsAt;
  bool _declined = false;
  bool _approvedNow = false;

  bool get _alreadyApproved =>
      widget.pendingState == 'witness_passed' && !_approvedNow && _windowEndsAt != null;

  bool get _canApprove => !_busy && !_terminal && !_declined && _windowEndsAt == null;
  bool get _canDecline => !_busy && !_terminal && !_declined;

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

  @override
  void initState() {
    super.initState();
    // A `witness_passed` entry from `pending` already has its window; showing
    // it beats an Approve button the next tap would have refused.
    if (widget.pendingState == 'witness_passed') {
      _windowEndsAt = widget.pendingWindowEndsAt;
    }
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final accepted = await ref.read(mfaResetApiProvider).approve(widget.requestId);
      if (!mounted) return;
      ref.invalidate(mfaResetPendingProvider);
      setState(() {
        _busy = false;
        _approvedNow = true;
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
      ref.invalidate(mfaResetPendingProvider);
      setState(() {
        _busy = false;
        _declined = true;
        // The request is cancelled; a window shown from `pending` is no longer
        // running, so do not leave it on screen beside "Declined".
        _windowEndsAt = null;
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
              Text(
                _intro(l10n),
                key: const ValueKey('mfaResetApproveIntro'),
                style: theme.textTheme.bodyMedium,
              ),
              if (_windowEndsAt != null) ...[
                const SizedBox(height: AppSpace.lg),
                Text(
                  _alreadyApproved ? l10n.mfaResetApproveAlready : l10n.mfaResetApproved,
                  key: _alreadyApproved
                      ? const ValueKey('mfaResetApproveAlready')
                      : const ValueKey('mfaResetApproved'),
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
              if (_canApprove || _canDecline) ...[
                const SizedBox(height: AppSpace.xl),
                if (_canApprove)
                  FilledButton.icon(
                    key: const ValueKey('mfaResetApprove'),
                    onPressed: _approve,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(l10n.mfaResetApproveAction),
                  ),
                if (_canApprove && _canDecline) const SizedBox(height: AppSpace.md),
                if (_canDecline)
                  OutlinedButton.icon(
                    key: const ValueKey('mfaResetDecline'),
                    onPressed: _decline,
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

  /// Names the requester when `pending` provided them; otherwise keeps the
  /// pre-list wording rather than inventing an identity.
  String _intro(AppLocalizations l10n) {
    final name = (widget.requesterName ?? '').trim();
    if (name.isEmpty) return l10n.mfaResetApproveIntro;
    final role = mfaResetRoleName(l10n, widget.requesterRole ?? '');
    return l10n.mfaResetApproveIntroNamed(
      name,
      role.isEmpty ? l10n.mfaResetRoleFamilyMember : role,
    );
  }

  String _format(BuildContext context, DateTime at) =>
      DateFormat.yMMMd(context.localeName).add_Hm().format(at.toLocal());
}

/// The `/mfa/reset/approve` deep link: a notification (decision 4's templates
/// are still unbuilt) or a link another parent handed over.
///
/// Only `requestId` comes from the URL. The requester's name, role and state
/// are read from `GET /v1/auth/mfa/reset/pending` and matched by id, so a
/// crafted link cannot put words in the requester's mouth ("X (owner) asked…")
/// or pass `state=witness_passed` to hide the Approve button. An id that is not
/// in the list — the caller's own request, one that already ended, a stale link
/// — falls back to the generic copy, and the API decides what may happen.
class MfaResetApprovalLink extends ConsumerWidget {
  const MfaResetApprovalLink({super.key, required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (requestId.isEmpty) return const MfaResetApprovalScreen(requestId: '');
    final pending = ref.watch(mfaResetPendingProvider);
    if (pending.isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.mfaResetApproveTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    MfaResetPendingRequest? match;
    for (final request in pending.valueOrNull ?? const <MfaResetPendingRequest>[]) {
      if (request.requestId == requestId) {
        match = request;
        break;
      }
    }
    return MfaResetApprovalScreen(
      requestId: requestId,
      requesterName: match?.requesterName,
      requesterRole: match?.requesterRole,
      pendingState: match?.state,
      pendingWindowEndsAt: match?.windowEndsAt,
    );
  }
}
