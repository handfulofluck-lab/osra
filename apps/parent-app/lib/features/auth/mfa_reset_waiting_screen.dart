import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/mfa_reset_api.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../theme/app_tokens.dart';
import '../settings/mfa_enroll_screen.dart';
import 'mfa_reset_messages.dart';
import 'mfa_reset_witness_screen.dart';

/// The three stages a request can be in while the parent waits (ADR-0031
/// decision 2). `mailbox_confirmed` is not a separate stage here: the app never
/// learns that the link was clicked (the link is a web page, and the API has no
/// read route), so the parent moves on by entering the code they can see.
enum MfaResetStage { awaitingMailbox, awaitingWitness, window }

/// What the waiting screen shows.
///
/// Every non-null field is a value the API returned in this session: the
/// request id and 30-minute mailbox deadline from `/reset/request`, the
/// 10-minute code deadline from `/reset/confirm`, the 72-hour window from
/// `/reset/witness` or `/reset/approve`.
///
/// **Nothing here is persisted, and it cannot be rebuilt after a restart.**
/// The API exposes no route that reads a request's state (`docs/SPEC.md`: the
/// read-only audit route of ADR-0031 decision 8 is not built), and the app is
/// required not to remember state locally. A resumed app therefore has to begin
/// again at [MfaResetRequestScreen]; that is the API gap, not a UI choice.
@immutable
class MfaResetProgress {
  final String requestId;
  final MfaResetStage stage;

  /// The address the parent typed, kept only so the final `complete` step can
  /// repeat it. Empty when the screen was opened without the request step.
  final String email;

  final DateTime? mailboxExpiresAt;
  final DateTime? codeExpiresAt;
  final DateTime? windowEndsAt;

  const MfaResetProgress({
    required this.requestId,
    required this.stage,
    this.email = '',
    this.mailboxExpiresAt,
    this.codeExpiresAt,
    this.windowEndsAt,
  });

  MfaResetProgress copyWith({
    MfaResetStage? stage,
    String? email,
    DateTime? mailboxExpiresAt,
    DateTime? codeExpiresAt,
    DateTime? windowEndsAt,
  }) =>
      MfaResetProgress(
        requestId: requestId,
        stage: stage ?? this.stage,
        email: email ?? this.email,
        mailboxExpiresAt: mailboxExpiresAt ?? this.mailboxExpiresAt,
        codeExpiresAt: codeExpiresAt ?? this.codeExpiresAt,
        windowEndsAt: windowEndsAt ?? this.windowEndsAt,
      );
}

/// The screen a parent comes back to while a reset is pending: the current
/// stage, the next thing to do, and how the request can be stopped.
///
/// There is no cancel button here, deliberately. The parent on this screen is
/// the one being reset, and the API gives them no in-app cancel: they hold no
/// session (`/cancel` answers `401 unauthorized`, or `session_revoked` once the
/// window has started), and a password-only cancel would let anyone holding
/// just the password block a genuine reset (ADR-0031 amendment 2026-10-23,
/// item 3). The screen names the two ways that work instead: the cancel link in
/// any email about the request, and a sign-in with the authenticator.
///
/// [onNow] is a test seam for the 72-hour boundary; production passes nothing.
class MfaResetWaitingScreen extends ConsumerStatefulWidget {
  const MfaResetWaitingScreen({super.key, required this.progress, this.onNow});

  final MfaResetProgress progress;
  final DateTime Function()? onNow;

  @override
  ConsumerState<MfaResetWaitingScreen> createState() => _MfaResetWaitingScreenState();
}

class _MfaResetWaitingScreenState extends ConsumerState<MfaResetWaitingScreen> {
  late MfaResetProgress _progress = widget.progress;

  DateTime get _now => (widget.onNow ?? DateTime.now)();

  bool get _windowDue {
    final ends = _progress.windowEndsAt;
    return _progress.stage == MfaResetStage.window && ends != null && !ends.isAfter(_now);
  }

  Future<void> _openWitness() async {
    final accepted = await Navigator.of(context).push<MfaResetWitnessAccepted>(MaterialPageRoute(
      builder: (_) => MfaResetWitnessScreen(requestId: _progress.requestId),
    ));
    if (accepted == null || !mounted) return;
    setState(() {
      _progress = _progress.copyWith(
        stage: MfaResetStage.window,
        windowEndsAt: accepted.windowEndsAt,
      );
    });
  }

  Future<void> _finish() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => _FinishResetDialog(
        requestId: _progress.requestId,
        initialEmail: _progress.email,
      ),
    );
    if (token == null || !mounted) return;
    await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
      builder: (_) => MfaEnrollScreen(recoveryToken: token),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final stage = _progress.stage;
    final (title, body) = switch (stage) {
      MfaResetStage.awaitingMailbox => (l10n.mfaResetStageMailboxTitle, l10n.mfaResetStageMailboxBody),
      MfaResetStage.awaitingWitness => (l10n.mfaResetStageWitnessTitle, l10n.mfaResetStageWitnessBody),
      MfaResetStage.window => (l10n.mfaResetStageWindowTitle, l10n.mfaResetStageWindowBody),
    };
    final deadline = switch (stage) {
      MfaResetStage.awaitingMailbox => _progress.mailboxExpiresAt == null
          ? null
          : l10n.mfaResetMailboxExpires(_format(context, _progress.mailboxExpiresAt!)),
      MfaResetStage.awaitingWitness => _progress.codeExpiresAt == null
          ? null
          : l10n.mfaResetCodeExpires(_format(context, _progress.codeExpiresAt!)),
      MfaResetStage.window => _progress.windowEndsAt == null
          ? null
          : l10n.mfaResetWindowEndsAt(_format(context, _progress.windowEndsAt!)),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaResetWaitingTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              title,
              key: const ValueKey('mfaResetStageTitle'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              body,
              key: const ValueKey('mfaResetStageBody'),
              style: theme.textTheme.bodyMedium,
            ),
            if (deadline != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                deadline,
                key: const ValueKey('mfaResetDeadline'),
                style: theme.textTheme.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            if (stage != MfaResetStage.window)
              FilledButton.icon(
                key: const ValueKey('mfaResetHaveCode'),
                onPressed: _openWitness,
                icon: const Icon(Icons.pin_outlined),
                label: Text(stage == MfaResetStage.awaitingWitness ? l10n.mfaResetEnterCode : l10n.mfaResetHaveCode),
              ),
            if (_windowDue) ...[
              Text(
                l10n.mfaResetWindowDue,
                key: const ValueKey('mfaResetWindowDue'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpace.sm),
              FilledButton.icon(
                key: const ValueKey('mfaResetFinish'),
                onPressed: _finish,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(l10n.mfaResetFinish),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            Text(
              l10n.mfaResetCancelHint,
              key: const ValueKey('mfaResetCancelHint'),
              style: theme.textTheme.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  String _format(BuildContext context, DateTime at) =>
      DateFormat.yMMMd(context.localeName).add_Hm().format(at.toLocal());
}

/// The end of the wait (ADR-0031 decision 5 → ADR-0023): the password, then
/// `complete`, which returns the 15-minute purpose-scoped token. The dialog
/// owns the call so a refusal is shown next to the fields that caused it.
class _FinishResetDialog extends ConsumerStatefulWidget {
  const _FinishResetDialog({required this.requestId, required this.initialEmail});

  final String requestId;
  final String initialEmail;

  @override
  ConsumerState<_FinishResetDialog> createState() => _FinishResetDialogState();
}

class _FinishResetDialogState extends ConsumerState<_FinishResetDialog> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _password = TextEditingController();
  bool _obscured = true;
  bool _submitting = false;
  MfaResetFailure? _failure;

  bool get _terminal => _failure != null &&
      const {
        MfaResetFailureKind.tooManyAttempts,
        MfaResetFailureKind.requestNotOpen,
        MfaResetFailureKind.requestCancelled,
        MfaResetFailureKind.requestExpired,
        MfaResetFailureKind.requestCompleted,
        MfaResetFailureKind.requestNotFound,
        MfaResetFailureKind.witnessRequired,
      }.contains(_failure!.kind);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _failure = const MfaResetFailure(MfaResetFailureKind.validation));
      return;
    }
    setState(() {
      _submitting = true;
      _failure = null;
    });
    try {
      final result = await ref.read(mfaResetApiProvider).complete(
            email: email,
            password: password,
            requestId: widget.requestId,
          );
      if (!mounted) return;
      Navigator.of(context).pop(result.recoveryToken);
    } on MfaResetFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _failure = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.mfaResetFinishTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.mfaResetFinishBody),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('mfaResetFinishEmail'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: l10n.emailLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('mfaResetFinishPassword'),
              controller: _password,
              obscureText: _obscured,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: l10n.passwordLabel,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_failure != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                _failure!.kind == MfaResetFailureKind.validation
                    ? l10n.mfaResetFieldsRequired
                    : mfaResetFailureText(l10n, _failure!.kind),
                key: const ValueKey('mfaResetFinishError'),
                style: TextStyle(color: context.tokens.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('mfaResetFinishSubmit'),
          onPressed: _submitting || _terminal ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.mfaResetFinishSubmit),
        ),
      ],
    );
  }
}
