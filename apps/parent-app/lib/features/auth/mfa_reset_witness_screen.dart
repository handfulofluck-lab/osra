import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/mfa_reset_api.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../theme/app_tokens.dart';
import 'mfa_reset_messages.dart';

/// Step 3a of ADR-0031: the 8-digit code shown on the paired child device.
///
/// The API needs no session here — the parent being reset cannot hold one — so
/// the request id (issued by `/request`, or read from the app's in-memory
/// progress) and the code are the whole proof.
///
/// The API's `401 invalid_witness` covers an unknown request id, an expired
/// code and a wrong code alike, and the screen keeps one message for all three.
/// It shows `attemptsRemaining` only when the server sent it, which it does for
/// a wrong code and for nothing else.
class MfaResetWitnessScreen extends ConsumerStatefulWidget {
  const MfaResetWitnessScreen({super.key, required this.requestId});

  final String requestId;

  @override
  ConsumerState<MfaResetWitnessScreen> createState() => _MfaResetWitnessScreenState();
}

class _MfaResetWitnessScreenState extends ConsumerState<MfaResetWitnessScreen> {
  final _code = TextEditingController();
  bool _submitting = false;
  MfaResetFailure? _failure;

  /// A refusal that ends the request: retrying cannot succeed, so the button is
  /// disabled rather than left as a trap.
  bool get _terminal => _failure != null &&
      const {
        MfaResetFailureKind.tooManyAttempts,
        MfaResetFailureKind.requestNotOpen,
        MfaResetFailureKind.requestCancelled,
        MfaResetFailureKind.requestExpired,
        MfaResetFailureKind.requestCompleted,
        MfaResetFailureKind.requestNotFound,
      }.contains(_failure!.kind);

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{8}$').hasMatch(code)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.mfaResetWitnessEnterCode)));
      return;
    }
    setState(() {
      _submitting = true;
      _failure = null;
    });
    try {
      final accepted = await ref
          .read(mfaResetApiProvider)
          .submitWitness(requestId: widget.requestId, code: code);
      if (!mounted) return;
      setState(() => _submitting = false);
      Navigator.of(context).pop(accepted);
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaResetWitnessTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(l10n.mfaResetWitnessIntro, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.lg),
            TextField(
              key: const ValueKey('mfaResetWitnessCode'),
              controller: _code,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: l10n.mfaResetWitnessLabel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
              ),
              onSubmitted: (_) {
                if (!_submitting && !_terminal) _submit();
              },
            ),
            if (_failure != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                mfaResetFailureText(
                  l10n,
                  _failure!.kind,
                  attemptsRemaining: _failure!.attemptsRemaining,
                ),
                key: const ValueKey('mfaResetWitnessError'),
                style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            FilledButton.icon(
              key: const ValueKey('mfaResetWitnessSubmit'),
              onPressed: _submitting || _terminal ? null : _submit,
              icon: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.pin_outlined),
              label: Text(l10n.mfaResetWitnessSubmit),
            ),
          ],
        ),
      ),
    );
  }
}
