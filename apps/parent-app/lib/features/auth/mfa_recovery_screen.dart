import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/mfa_api.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../theme/app_tokens.dart';
import '../settings/mfa_enroll_screen.dart';
import '../settings/mfa_messages.dart';

/// "Lost your authenticator?" — email + password + one unused recovery code.
///
/// On success the API returns a 15-minute `purpose:"mfa_recovery"` token, not a
/// session. The screen hands it straight to [MfaEnrollScreen] and never writes
/// it to storage; every other route would refuse it anyway.
class MfaRecoveryScreen extends ConsumerStatefulWidget {
  const MfaRecoveryScreen({super.key});

  @override
  ConsumerState<MfaRecoveryScreen> createState() => _MfaRecoveryScreenState();
}

class _MfaRecoveryScreenState extends ConsumerState<MfaRecoveryScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _obscured = true;
  bool _submitting = false;
  MfaFailureKind? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    final code = _code.text.trim();
    if (email.isEmpty || password.isEmpty || code.isEmpty) {
      setState(() => _error = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.mfaFieldsRequired)));
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final token = await ref.read(mfaApiProvider).recover(
            email: email,
            password: password,
            code: code,
          );
      if (!mounted) return;
      setState(() => _submitting = false);
      await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
        builder: (_) => MfaEnrollScreen(recoveryToken: token),
      ));
    } on MfaFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = failure.kind;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mfaRecoveryTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(l10n.mfaRecoveryIntro, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.lg),
            TextField(
              key: const ValueKey('mfaRecoveryEmail'),
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
              key: const ValueKey('mfaRecoveryPassword'),
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
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('mfaRecoveryCode'),
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.mfaRecoveryCodeLabel,
                hintText: l10n.mfaRecoveryCodeHint,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) {
                if (!_submitting) _submit();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                _error == MfaFailureKind.malformed
                    ? l10n.mfaRecoveryNoToken
                    : mfaFailureText(l10n, _error!, recoveryFlow: true),
                key: const ValueKey('mfaRecoveryError'),
                style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            FilledButton.icon(
              key: const ValueKey('mfaRecoverySubmit'),
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.key_off_outlined),
              label: Text(l10n.mfaRecoverySubmit),
            ),
          ],
        ),
      ),
    );
  }
}
