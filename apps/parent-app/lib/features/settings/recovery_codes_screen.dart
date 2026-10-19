import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// The one-time display of a recovery-code batch (ADR-0023).
///
/// The API stores only hashes and has no "show again" route, so this screen is
/// the only chance to save them. [onExit] is the caller's navigation: a session
/// flow signs out (verification revoked every session), while the recovery flow
/// returns to login. When it is null the screen simply pops.
class RecoveryCodesScreen extends StatefulWidget {
  const RecoveryCodesScreen({super.key, required this.batch, this.onExit});

  final RecoveryCodeBatch batch;
  final VoidCallback? onExit;

  @override
  State<RecoveryCodesScreen> createState() => _RecoveryCodesScreenState();
}

class _RecoveryCodesScreenState extends State<RecoveryCodesScreen> {
  bool _saved = false;

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: widget.batch.codes.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.mfaCodesCopied)));
  }

  void _exit() {
    final onExit = widget.onExit;
    if (onExit != null) {
      onExit();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Back without confirming is allowed once the parent has seen the warning:
  /// the codes cannot be recovered, so leaving is a deliberate loss.
  Future<void> _confirmLeave() async {
    final l10n = context.l10n;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.mfaCodesLeaveTitle),
        content: Text(l10n.mfaCodesLeaveBody),
        actions: [
          TextButton(
            key: const ValueKey('recoveryCodesStay'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.mfaCodesStay),
          ),
          FilledButton(
            key: const ValueKey('recoveryCodesLeave'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.mfaCodesLeave),
          ),
        ],
      ),
    );
    if (leave == true && mounted) _exit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final issuedAt = widget.batch.issuedAt;
    return PopScope(
      // The system back gesture and the AppBar arrow both route through
      // maybePop, so neither can drop the only plaintext copy silently.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.mfaCodesTitle)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Text(l10n.mfaCodesIntro, style: theme.textTheme.titleMedium),
              if (issuedAt != null) ...[
                const SizedBox(height: AppSpace.xs),
                Text(
                  l10n.mfaCodesIssuedAt(
                    MaterialLocalizations.of(context).formatCompactDate(issuedAt.toLocal()),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.tokens.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg,
                    vertical: AppSpace.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.batch.codes.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                          child: Semantics(
                            label: l10n.mfaRecoveryCodeSemantics(i + 1),
                            child: SelectableText(
                              widget.batch.codes[i],
                              key: ValueKey('recoveryCode$i'),
                              style: AppType.recoveryCode.copyWith(
                                color: context.tokens.onSurface,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              FilledButton.tonalIcon(
                key: const ValueKey('recoveryCodesCopy'),
                onPressed: widget.batch.isEmpty ? null : _copyAll,
                icon: const Icon(Icons.copy),
                label: Text(l10n.mfaCopyAllCodes),
              ),
              const SizedBox(height: AppSpace.lg),
              CheckboxListTile(
                key: const ValueKey('recoveryCodesSavedCheck'),
                contentPadding: EdgeInsets.zero,
                value: _saved,
                onChanged: (v) => setState(() => _saved = v ?? false),
                title: Text(l10n.mfaCodesSavedCheckbox),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: AppSpace.sm),
              FilledButton.icon(
                key: const ValueKey('recoveryCodesConfirm'),
                onPressed: _saved ? _exit : null,
                icon: const Icon(Icons.check),
                label: Text(l10n.mfaCodesConfirm),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
