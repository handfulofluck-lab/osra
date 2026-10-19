import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/mfa_api.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/mfa_provider.dart';
import '../../theme/app_tokens.dart';
import 'mfa_messages.dart';
import 'reauth_dialog.dart';
import 'recovery_codes_screen.dart';

/// Two-step enrolment: fetch a secret, show it as a QR, verify a six-digit
/// code, then hand off to the show-once recovery-code screen.
///
/// A first enrolment needs only the session. Replacing a secret needs the #139
/// proof — the screen does not assume which case it is in; when the API answers
/// `401 reauth_required` it asks for the password (or a current code) and
/// retries exactly once with that proof.
///
/// [recoveryToken] is the 15-minute `purpose:"mfa_recovery"` token issued by
/// `/mfa/recover`. It is used only for `/mfa/enroll` and `/mfa/verify` and is
/// never stored as the session.
class MfaEnrollScreen extends ConsumerStatefulWidget {
  const MfaEnrollScreen({super.key, this.recoveryToken});

  final String? recoveryToken;

  @override
  ConsumerState<MfaEnrollScreen> createState() => _MfaEnrollScreenState();
}

class _MfaEnrollScreenState extends ConsumerState<MfaEnrollScreen> {
  final _code = TextEditingController();
  MfaEnrollment? _enrollment;
  bool _starting = true;
  bool _verifying = false;
  MfaFailureKind? _startError;
  MfaFailureKind? _verifyError;
  bool _noCodes = false;
  bool _proofCancelled = false;

  bool get _recoveryFlow => widget.recoveryToken != null;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _start({ReauthProof? proof}) async {
    setState(() {
      _starting = true;
      _startError = null;
      _proofCancelled = false;
    });
    try {
      final enrollment = await ref.read(mfaApiProvider).enroll(
            password: proof?.password,
            code: proof?.code,
            bearerToken: widget.recoveryToken,
          );
      if (!mounted) return;
      setState(() {
        _enrollment = enrollment;
        _starting = false;
      });
    } on MfaFailure catch (failure) {
      if (!mounted) return;
      // A replacement secret needs proof. Ask once, then either retry with it
      // or show the honest reason (the parent cancelled / the proof was wrong).
      if (failure.kind == MfaFailureKind.reauthRequired && !_recoveryFlow && proof == null) {
        setState(() => _starting = false);
        final next = await showReauthDialog(context);
        if (!mounted) return;
        if (next != null) {
          await _start(proof: next);
        } else {
          setState(() {
            _startError = MfaFailureKind.reauthRequired;
            _proofCancelled = true;
          });
        }
        return;
      }
      setState(() {
        _starting = false;
        _startError = failure.kind;
      });
    }
  }

  Future<void> _copySecret() async {
    final secret = _enrollment?.secret;
    if (secret == null) return;
    await Clipboard.setData(ClipboardData(text: secret));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.mfaSecretCopied)));
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _verifyError = MfaFailureKind.invalidCode);
      return;
    }
    setState(() {
      _verifying = true;
      _verifyError = null;
      _noCodes = false;
    });
    try {
      final batch = await ref.read(mfaApiProvider).verify(
            code,
            bearerToken: widget.recoveryToken,
          );
      if (!mounted) return;
      if (batch.isEmpty) {
        // A 2xx without codes means the plaintext batch cannot be shown; do not
        // pretend enrolment finished and leave the parent with nothing.
        setState(() {
          _verifying = false;
          _noCodes = true;
        });
        return;
      }
      setState(() => _verifying = false);
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => RecoveryCodesScreen(
          batch: batch,
          onExit: _recoveryFlow ? _finishRecoveryFlow : _finishSessionFlow,
        ),
      ));
    } on MfaFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _verifyError = failure.kind;
      });
    }
  }

  /// `/mfa/verify` revokes every session. Signing out locally and telling the
  /// login screen why is the honest state, not a silent 401 on the next tap.
  void _finishSessionFlow() {
    unawaited(_signOutForMfa());
  }

  Future<void> _signOutForMfa() async {
    ref.read(loginNoticeProvider.notifier).state = kLoginNoticeMfaSessionEnded;
    await ref.read(authProvider.notifier).logout();
    if (mounted) context.go('/login');
  }

  /// Recovery is a temporary flow started from the login screen: the root route
  /// is the login form, so returning there is done once the codes are saved.
  void _finishRecoveryFlow() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaEnrollTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            if (_recoveryFlow) ...[
              Text(l10n.mfaEnrollAfterRecovery, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpace.lg),
            ],
            if (_starting)
              const Padding(
                padding: EdgeInsets.all(AppSpace.xxl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_startError != null)
              _startErrorView(l10n, theme)
            else if (_enrollment != null)
              ..._enrollmentView(l10n, theme),
          ],
        ),
      ),
    );
  }

  Widget _startErrorView(AppLocalizations l10n, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _proofCancelled
              ? l10n.mfaReauthRequired
              : _startError == MfaFailureKind.malformed
                  ? l10n.mfaEnrollError
                  : mfaFailureText(l10n, _startError!, recoveryFlow: _recoveryFlow),
          key: const ValueKey('mfaEnrollError'),
          style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
        ),
        const SizedBox(height: AppSpace.md),
        FilledButton.tonal(
          key: const ValueKey('mfaEnrollRetry'),
          onPressed: _starting ? null : () => _start(),
          child: Text(l10n.tryAgain),
        ),
      ],
    );
  }

  List<Widget> _enrollmentView(AppLocalizations l10n, ThemeData theme) {
    final enrollment = _enrollment!;
    return [
      Text(l10n.mfaEnrollIntro, style: theme.textTheme.bodyMedium),
      const SizedBox(height: AppSpace.lg),
      Center(
        child: Card(
          // A QR on a dark surface does not scan; keep the symbol black on white.
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: MfaQr(
              key: const ValueKey('mfaEnrollQr'),
              data: enrollment.otpauthUrl,
              semanticsLabel: l10n.mfaSecretSemantics,
            ),
          ),
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      Text(l10n.mfaEnrollManual, style: theme.textTheme.bodySmall),
      const SizedBox(height: AppSpace.xs),
      Row(
        children: [
          Expanded(
            child: SelectableText(
              enrollment.secret,
              key: const ValueKey('mfaEnrollSecret'),
              style: AppType.recoveryCode.copyWith(color: context.tokens.onSurface),
            ),
          ),
          IconButton(
            key: const ValueKey('mfaEnrollCopySecret'),
            tooltip: l10n.mfaSecretCopied,
            onPressed: _copySecret,
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      const SizedBox(height: AppSpace.xl),
      TextField(
        key: const ValueKey('mfaEnrollCode'),
        controller: _code,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        decoration: InputDecoration(
          labelText: l10n.mfaCodeFieldLabel,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) {
          if (!_verifying) _verify();
        },
      ),
      if (_noCodes) ...[
        const SizedBox(height: AppSpace.md),
        Text(
          l10n.mfaNoRecoveryCodes,
          key: const ValueKey('mfaVerifyNoCodes'),
          style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
        ),
      ],
      if (_verifyError != null) ...[
        const SizedBox(height: AppSpace.md),
        Text(
          mfaFailureText(l10n, _verifyError!, recoveryFlow: _recoveryFlow),
          key: const ValueKey('mfaVerifyError'),
          style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
        ),
      ],
      const SizedBox(height: AppSpace.lg),
      FilledButton.icon(
        key: const ValueKey('mfaVerifyButton'),
        onPressed: _verifying ? null : _verify,
        icon: _verifying
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.verified_user_outlined),
        label: Text(_verifying ? l10n.mfaVerifying : l10n.mfaVerify),
      ),
    ];
  }
}

/// The QR symbol, split out so tests can read the encoded URL (the package's
/// [QrImageView] keeps its own copy private).
class MfaQr extends StatelessWidget {
  const MfaQr({super.key, required this.data, this.semanticsLabel});

  final String data;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: 200,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      ),
    );
  }
}
