import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/mfa_reset_api.dart';
import '../../l10n/l10n.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/mfa_reset_provider.dart';
import '../../theme/app_tokens.dart';
import 'mfa_reset_messages.dart';
import 'mfa_reset_waiting_screen.dart';

/// Step 1 of ADR-0031: the account password and the account's mailbox.
///
/// Reached from the login screen's "Lost your authenticator?" recovery screen
/// (for a parent with no recovery code left) and from Settings › Two-step
/// verification. It asks for nothing else: no child device is contacted until
/// the mailbox link is clicked, so this screen cannot say whether a code will
/// appear.
///
/// On success it replaces itself with [MfaResetWaitingScreen] and keeps the
/// request id and address in secure storage (never the password), so a restart
/// can resume at the waiting screen.
///
/// On open it checks for such a saved request first: if one exists this screen
/// is replaced at once by the waiting screen's resume path, which asks for the
/// password once and re-reads the stage. Starting over is not the only option a
/// restarted app offers.
class MfaResetRequestScreen extends ConsumerStatefulWidget {
  const MfaResetRequestScreen({super.key});

  @override
  ConsumerState<MfaResetRequestScreen> createState() => _MfaResetRequestScreenState();
}

class _MfaResetRequestScreenState extends ConsumerState<MfaResetRequestScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscured = true;
  bool _submitting = false;
  MfaResetFailureKind? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeStoredRequest());
  }

  Future<void> _resumeStoredRequest() async {
    final stored = await ref.read(mfaResetStoreProvider).read();
    if (!mounted || stored == null) return;
    await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
      builder: (_) => const MfaResetWaitingScreen(),
    ));
  }

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
      setState(() => _error = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.mfaResetFieldsRequired)));
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ref.read(mfaResetApiProvider).request(
            email: email,
            password: password,
          );
      if (!mounted) return;
      // Persist before leaving: the request outlives this process, the password
      // does not.
      await ref.read(mfaResetStoreProvider).save(requestId: result.requestId, email: email);
      if (!mounted) return;
      setState(() => _submitting = false);
      await Navigator.of(context).pushReplacement<void, void>(MaterialPageRoute(
        builder: (_) => MfaResetWaitingScreen(
          progress: MfaResetProgress(
            requestId: result.requestId,
            stage: MfaResetStage.awaitingMailbox,
            email: email,
            mailboxExpiresAt: result.expiresAt,
          ),
        ),
      ));
    } on MfaResetFailure catch (failure) {
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
      appBar: AppBar(title: Text(l10n.mfaResetTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(l10n.mfaResetIntro, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.lg),
            TextField(
              key: const ValueKey('mfaResetEmail'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: l10n.emailLabel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('mfaResetPassword'),
              controller: _password,
              obscureText: _obscured,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: l10n.passwordLabel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                suffixIcon: IconButton(
                  icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
              onSubmitted: (_) {
                if (!_submitting) _submit();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                mfaResetFailureText(l10n, _error!),
                key: const ValueKey('mfaResetError'),
                style: theme.textTheme.bodyMedium?.copyWith(color: context.tokens.danger),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            FilledButton.icon(
              key: const ValueKey('mfaResetSubmit'),
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.mark_email_unread_outlined),
              label: Text(l10n.mfaResetSubmit),
            ),
          ],
        ),
      ),
    );
  }
}
