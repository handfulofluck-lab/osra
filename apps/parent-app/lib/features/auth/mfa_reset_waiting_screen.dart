import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/mfa_reset_api.dart';
import '../../api/mfa_reset_store.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../theme/app_tokens.dart';
import '../settings/mfa_enroll_screen.dart';
import 'mfa_reset_messages.dart';
import 'mfa_reset_request_screen.dart';
import 'mfa_reset_witness_screen.dart';

/// The three stages a request can be in while the parent waits (ADR-0031
/// decision 2). `mailbox_confirmed` is not a separate stage here: the app never
/// learns that the link was clicked until it re-reads the request, so the
/// parent moves on by entering the code they can see.
enum MfaResetStage { awaitingMailbox, awaitingWitness, window }

/// Why a request stopped, as much as the API's vocabulary allows.
///
/// `cancelled_*` is one user-facing outcome (the request was stopped) with a
/// separate sentence for `cancelled_by_signin`, because that one is the parent's
/// own successful sign-in and the most confusing. [completed] is success, not a
/// failure, and has no "start again" action.
enum MfaResetTerminal {
  signinCancelled,
  cancelled,
  expired,
  tooManyAttempts,
  completed,
  notFound,
  unknown,
}

/// What the waiting screen shows.
///
/// Every non-null date is a value the API returned for this request: the
/// 30-minute mailbox deadline while `requested`, the code deadline while
/// `mailbox_confirmed`, and the 72-hour window once the witness passed.
///
/// [resumed] marks a state rebuilt from `POST /mfa/reset/status` after a
/// restart. `witnessKind` is still null until the witness passes, but
/// `codeExpiresAt` is not: it is set only when the family had a paired device,
/// so a null one means a co-parent is the only possible witness and [deviceCode]
/// is false.
@immutable
class MfaResetProgress {
  final String requestId;
  final MfaResetStage stage;

  /// The address the parent typed, kept only so `status` and the final
  /// `complete` step can repeat it. Empty when the screen was opened without
  /// the request step.
  final String email;

  final DateTime? mailboxExpiresAt;
  final DateTime? codeExpiresAt;
  final DateTime? windowEndsAt;

  /// The 24-hour deadline for the witness step, from `/status` while
  /// `mailbox_confirmed`. Null on a live screen, which has not asked.
  final DateTime? witnessDeadline;

  /// Whether the family had a paired device when the mailbox link was opened,
  /// so a code was issued. `false` means no code exists and only another parent
  /// can witness; the screen then offers no code entry. True until `/status`
  /// says otherwise, because a live screen reached this stage by "I have the
  /// code".
  final bool deviceCode;

  final bool resumed;

  const MfaResetProgress({
    required this.requestId,
    required this.stage,
    this.email = '',
    this.mailboxExpiresAt,
    this.codeExpiresAt,
    this.windowEndsAt,
    this.witnessDeadline,
    this.deviceCode = true,
    this.resumed = false,
  });

  MfaResetProgress copyWith({
    MfaResetStage? stage,
    String? email,
    DateTime? mailboxExpiresAt,
    DateTime? codeExpiresAt,
    DateTime? windowEndsAt,
    DateTime? witnessDeadline,
    bool? deviceCode,
    bool? resumed,
  }) =>
      MfaResetProgress(
        requestId: requestId,
        stage: stage ?? this.stage,
        email: email ?? this.email,
        mailboxExpiresAt: mailboxExpiresAt ?? this.mailboxExpiresAt,
        codeExpiresAt: codeExpiresAt ?? this.codeExpiresAt,
        windowEndsAt: windowEndsAt ?? this.windowEndsAt,
        witnessDeadline: witnessDeadline ?? this.witnessDeadline,
        deviceCode: deviceCode ?? this.deviceCode,
        resumed: resumed ?? this.resumed,
      );
}

/// The screen a parent comes back to while a reset is pending: the current
/// stage, the next thing to do, and how the request can be stopped.
///
/// Opened in two ways:
/// - **live**, with [progress] from the `/request` call this session made; and
/// - **resumed** (`progress == null`), after a restart. The screen reads the
///   stored request id and address, asks for the password once, and calls
///   `POST /mfa/reset/status` to rebuild the stage. The password is never
///   stored; it lives in the field until that one call returns. A `404
///   request_not_found` means the request is gone and the parent starts again.
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
  const MfaResetWaitingScreen({super.key, this.progress, this.onNow});

  final MfaResetProgress? progress;
  final DateTime Function()? onNow;

  @override
  ConsumerState<MfaResetWaitingScreen> createState() => _MfaResetWaitingScreenState();
}

class _MfaResetWaitingScreenState extends ConsumerState<MfaResetWaitingScreen> {
  MfaResetProgress? _progress;
  StoredMfaReset? _stored;
  MfaResetTerminal? _terminal;
  MfaResetFailure? _resumeFailure;
  bool _loadingStored = false;
  bool _checking = false;
  final _resumePassword = TextEditingController();

  bool get _resumeMode => _progress == null;

  DateTime get _now => (widget.onNow ?? DateTime.now)();

  bool get _windowDue {
    final progress = _progress;
    final ends = progress?.windowEndsAt;
    return progress != null && progress.stage == MfaResetStage.window && ends != null && !ends.isAfter(_now);
  }

  /// Whether the deadline this stage waits on has already run out, read from
  /// the same [_now] as [_windowDue].
  ///
  /// `window` is deliberately exempt: a new request there is answered
  /// `409 reset_already_pending`, so start-again would be a button that cannot
  /// work. The API keeps a request in `requested` or `mailbox_confirmed` after
  /// its own deadline, so without this the parent loops between this screen and
  /// the request screen until the 24-hour sweep expires the row.
  bool get _deadlinePassed {
    final ends = _deadline;
    return ends != null && !ends.isAfter(_now);
  }

  /// ADR-0031: a device code lives `MFA_RESET_CODE_TTL_SECONDS` (10 minutes,
  /// `services/api/src/lib/mfaReset.ts`). A link opened in its last second issues
  /// a code valid this much longer, so the mailbox stage really ends here — and
  /// start-again three seconds after the link expires would supersede a request
  /// whose code is still usable, spending one of three attempts in 30 days.
  static const Duration _resetCodeLifetime = Duration(minutes: 10);

  /// The moment this stage can no longer move forward, or null when it has no
  /// deadline of its own.
  DateTime? get _deadline {
    final progress = _progress;
    return switch (progress?.stage) {
      MfaResetStage.awaitingMailbox => progress?.mailboxExpiresAt?.add(_resetCodeLifetime),
      // With no device code there is no code deadline: the witness is a co-parent,
      // and the only clock left is the 24-hour approval deadline.
      MfaResetStage.awaitingWitness =>
          (progress?.deviceCode ?? true) ? progress?.codeExpiresAt : progress?.witnessDeadline,
      _ => null,
    };
  }

  @override
  void initState() {
    super.initState();
    _progress = widget.progress;
    if (_progress == null) {
      _loadingStored = true;
      _loadStored();
    }
  }

  @override
  void dispose() {
    _resumePassword.dispose();
    super.dispose();
  }

  Future<void> _loadStored() async {
    final stored = await ref.read(mfaResetStoreProvider).read();
    if (!mounted) return;
    setState(() {
      _stored = stored;
      _loadingStored = false;
    });
  }

  Future<void> _checkStatus() async {
    final stored = _stored;
    if (stored == null) return;
    final password = _resumePassword.text;
    if (password.isEmpty) {
      setState(() => _resumeFailure = const MfaResetFailure(MfaResetFailureKind.validation));
      return;
    }
    // Read before the call, not after: a terminal state or a 404 must still
    // forget the id, and that answer can arrive once this screen is gone.
    final store = ref.read(mfaResetStoreProvider);
    setState(() {
      _checking = true;
      _resumeFailure = null;
    });
    try {
      final status = await ref.read(mfaResetApiProvider).status(
            email: stored.email,
            password: password,
            requestId: stored.requestId,
          );
      final terminal = _terminalFor(status.state);
      if (terminal != null) await store.clear();
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (terminal != null) {
          _terminal = terminal;
        } else {
          _progress = _progressFromStatus(status, stored.email);
        }
      });
    } on MfaResetFailure catch (failure) {
      if (failure.kind == MfaResetFailureKind.requestNotFound) await store.clear();
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (failure.kind == MfaResetFailureKind.requestNotFound) {
          _terminal = MfaResetTerminal.notFound;
        } else {
          _resumeFailure = failure;
        }
      });
    } finally {
      // The password is asked for this one call and then dropped: it is never
      // written anywhere, and no later screen reads it. It must go even when
      // the call throws, and only while the field that owns it still exists.
      if (mounted) _resumePassword.clear();
    }
  }

  /// Only the three open states map to a stage. Everything else ended.
  MfaResetProgress? _progressFromStatus(MfaResetStatusView status, String email) =>
      switch (status.state) {
        'requested' => MfaResetProgress(
            requestId: status.requestId,
            stage: MfaResetStage.awaitingMailbox,
            email: email,
            mailboxExpiresAt: status.mailboxLinkExpiresAt,
            resumed: true,
          ),
        'mailbox_confirmed' => MfaResetProgress(
            requestId: status.requestId,
            stage: MfaResetStage.awaitingWitness,
            email: email,
            codeExpiresAt: status.codeExpiresAt,
            witnessDeadline: status.witnessDeadline,
            // The API issues a code only when the family has a paired device;
            // no code deadline therefore means a co-parent is the only witness.
            deviceCode: status.codeExpiresAt != null,
            resumed: true,
          ),
        'witness_passed' => MfaResetProgress(
            requestId: status.requestId,
            stage: MfaResetStage.window,
            email: email,
            windowEndsAt: status.windowEndsAt,
            resumed: true,
          ),
        _ => null,
      };

  MfaResetTerminal? _terminalFor(String state) => switch (state) {
        'cancelled_by_signin' => MfaResetTerminal.signinCancelled,
        'cancelled_by_link' || 'cancelled_by_parent' => MfaResetTerminal.cancelled,
        'expired' => MfaResetTerminal.expired,
        'too_many_attempts' => MfaResetTerminal.tooManyAttempts,
        'completed' => MfaResetTerminal.completed,
        'requested' || 'mailbox_confirmed' || 'witness_passed' => null,
        _ => MfaResetTerminal.unknown,
      };

  Future<void> _forgetRequest() => ref.read(mfaResetStoreProvider).clear();

  Future<void> _startAgain() async {
    await _forgetRequest();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
      builder: (_) => const MfaResetRequestScreen(),
    ));
  }

  Future<void> _openWitness() async {
    final progress = _progress;
    if (progress == null) return;
    final accepted = await Navigator.of(context).push<MfaResetWitnessAccepted>(MaterialPageRoute(
      builder: (_) => MfaResetWitnessScreen(requestId: progress.requestId),
    ));
    if (accepted == null || !mounted) return;
    setState(() {
      _progress = progress.copyWith(
        stage: MfaResetStage.window,
        windowEndsAt: accepted.windowEndsAt,
      );
    });
  }

  Future<void> _finish() async {
    final progress = _progress;
    if (progress == null) return;
    final token = await showDialog<String>(
      context: context,
      builder: (_) => _FinishResetDialog(
        requestId: progress.requestId,
        initialEmail: progress.email.isEmpty ? (_stored?.email ?? '') : progress.email,
      ),
    );
    if (token == null || !mounted) return;
    await _forgetRequest();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
      builder: (_) => MfaEnrollScreen(recoveryToken: token),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_loadingStored) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.mfaResetWaitingTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_terminal != null) return _terminalScaffold(context, _terminal!);
    if (_resumeMode) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.mfaResetResumeTitle)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: _stored == null
                ? [
                    Text(l10n.mfaResetResumeNone, key: const ValueKey('mfaResetResumeNone')),
                    const SizedBox(height: AppSpace.lg),
                    FilledButton(
                      key: const ValueKey('mfaResetStartAgain'),
                      onPressed: _startAgain,
                      child: Text(l10n.mfaResetStartNewRequest),
                    ),
                  ]
                : _resumeFields(context, l10n, _stored!),
          ),
        ),
      );
    }
    return _progressScaffold(context, l10n, _progress!);
  }

  List<Widget> _resumeFields(BuildContext context, AppLocalizations l10n, StoredMfaReset stored) {
    final theme = Theme.of(context);
    return [
      Text(
        l10n.mfaResetResumeBody,
        key: const ValueKey('mfaResetResumeBody'),
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: AppSpace.lg),
      Text(
        stored.email,
        key: const ValueKey('mfaResetResumeEmail'),
        style: theme.textTheme.bodyLarge,
      ),
      const SizedBox(height: AppSpace.md),
      TextField(
        key: const ValueKey('mfaResetResumePassword'),
        controller: _resumePassword,
        obscureText: true,
        autofillHints: const [AutofillHints.password],
        decoration: InputDecoration(
          labelText: l10n.passwordLabel,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        ),
        onSubmitted: (_) {
          if (!_checking) _checkStatus();
        },
      ),
      if (_resumeFailure != null) ...[
        const SizedBox(height: AppSpace.md),
        Text(
          _resumeFailure!.kind == MfaResetFailureKind.validation
              ? l10n.mfaResetResumePasswordRequired
              : mfaResetFailureText(l10n, _resumeFailure!.kind),
          key: const ValueKey('mfaResetResumeError'),
          style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
        ),
      ],
      const SizedBox(height: AppSpace.lg),
      FilledButton.icon(
        key: const ValueKey('mfaResetResumeSubmit'),
        onPressed: _checking ? null : _checkStatus,
        icon: _checking
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.lock_open),
        label: Text(l10n.mfaResetResumeSubmit),
      ),
    ];
  }

  Widget _progressScaffold(BuildContext context, AppLocalizations l10n, MfaResetProgress progress) {
    final theme = Theme.of(context);
    final stage = progress.stage;
    final bool neutralWitness = stage == MfaResetStage.awaitingWitness && progress.resumed;
    final (title, body) = switch (stage) {
      MfaResetStage.awaitingMailbox => (l10n.mfaResetStageMailboxTitle, l10n.mfaResetStageMailboxBody),
      MfaResetStage.awaitingWitness => neutralWitness
          ? (l10n.mfaResetStageWitnessTitleResumed, l10n.mfaResetStageWitnessBodyResumed)
          : (l10n.mfaResetStageWitnessTitle, l10n.mfaResetStageWitnessBody),
      MfaResetStage.window => (l10n.mfaResetStageWindowTitle, l10n.mfaResetStageWindowBody),
    };
    final deadline = switch (stage) {
      MfaResetStage.awaitingMailbox => progress.mailboxExpiresAt == null
          ? null
          : l10n.mfaResetMailboxExpires(_format(context, progress.mailboxExpiresAt!)),
      MfaResetStage.awaitingWitness => progress.codeExpiresAt == null
          ? null
          : l10n.mfaResetCodeExpires(_format(context, progress.codeExpiresAt!)),
      MfaResetStage.window => progress.windowEndsAt == null
          ? null
          : l10n.mfaResetWindowEndsAt(_format(context, progress.windowEndsAt!)),
    };
    final deadlinePassed = _deadlinePassed;
    // No device code means no code exists to type: only another owner or
    // co-parent can witness, and the screen says when that must happen.
    final coParentOnly = stage == MfaResetStage.awaitingWitness && !progress.deviceCode;
    // Only while the deadline is still ahead: a past "by {time}" next to a
    // start-again button would read as a reason to wait for something that cannot
    // arrive (#314 review).
    final coParentDeadline = coParentOnly && !deadlinePassed && progress.witnessDeadline != null
        ? l10n.mfaResetAwaitingCoParent(_format(context, progress.witnessDeadline!))
        : null;
    final offerCode = stage != MfaResetStage.window && !deadlinePassed && !coParentOnly;
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
            if (coParentDeadline != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                coParentDeadline,
                key: const ValueKey('mfaResetAwaitingCoParent'),
                style: theme.textTheme.bodySmall?.copyWith(color: context.tokens.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            if (offerCode)
              FilledButton.icon(
                key: const ValueKey('mfaResetHaveCode'),
                onPressed: _openWitness,
                icon: const Icon(Icons.pin_outlined),
                label: Text(stage == MfaResetStage.awaitingWitness ? l10n.mfaResetEnterCode : l10n.mfaResetHaveCode),
              ),
            if (deadlinePassed) ...[
              Text(
                l10n.mfaResetDeadlinePassed,
                key: const ValueKey('mfaResetDeadlinePassed'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpace.sm),
              FilledButton.icon(
                key: const ValueKey('mfaResetStartAgain'),
                onPressed: _startAgain,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.mfaResetStartNewRequest),
              ),
            ],
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

  Widget _terminalScaffold(BuildContext context, MfaResetTerminal terminal) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final body = switch (terminal) {
      MfaResetTerminal.signinCancelled => l10n.mfaResetTerminalSigninCancelled,
      MfaResetTerminal.cancelled => l10n.mfaResetTerminalCancelled,
      MfaResetTerminal.expired => l10n.mfaResetTerminalExpired,
      MfaResetTerminal.tooManyAttempts => l10n.mfaResetTerminalTooManyAttempts,
      MfaResetTerminal.completed => l10n.mfaResetTerminalCompleted,
      MfaResetTerminal.notFound => l10n.mfaResetTerminalNotFound,
      MfaResetTerminal.unknown => l10n.mfaResetTerminalUnknown,
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaResetWaitingTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              l10n.mfaResetTerminalTitle,
              key: const ValueKey('mfaResetTerminalTitle'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              body,
              key: const ValueKey('mfaResetTerminalBody'),
              style: theme.textTheme.bodyMedium,
            ),
            if (terminal != MfaResetTerminal.completed) ...[
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                key: const ValueKey('mfaResetStartAgain'),
                onPressed: _startAgain,
                child: Text(l10n.mfaResetStartNewRequest),
              ),
            ],
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
