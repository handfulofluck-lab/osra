import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// The #139 proof of parentage: the account password, or a code from the
/// current authenticator. The API accepts either; the dialog requires at least
/// one and refuses to send an empty proof.
@immutable
class ReauthProof {
  final String password;
  final String code;

  const ReauthProof({this.password = '', this.code = ''});

  bool get isEmpty => password.trim().isEmpty && code.trim().isEmpty;
}

/// Returns null when the parent cancels — the caller must then do nothing
/// rather than retrying the privileged call without proof.
Future<ReauthProof?> showReauthDialog(BuildContext context) {
  return showDialog<ReauthProof>(
    context: context,
    builder: (_) => const ReauthDialog(),
  );
}

class ReauthDialog extends StatefulWidget {
  const ReauthDialog({super.key});

  @override
  State<ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<ReauthDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _obscured = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final proof = ReauthProof(password: _password.text, code: _code.text.trim());
    if (proof.isEmpty) {
      setState(() => _error = context.l10n.mfaReauthRequired);
      return;
    }
    Navigator.of(context).pop(proof);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.mfaReauthTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.mfaReauthExplanation),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('reauthPassword'),
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
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('reauthCode'),
              controller: _code,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(
                labelText: l10n.mfaReauthCode,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                _error!,
                key: const ValueKey('reauthError'),
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
          key: const ValueKey('reauthConfirm'),
          onPressed: _submit,
          child: Text(l10n.continueLabel),
        ),
      ],
    );
  }
}
