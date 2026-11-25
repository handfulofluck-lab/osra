import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import 'owner_presence_prompt.dart';

/// Issue #742, Claude's ruling (2026-11-25): a phone with neither biometrics nor a screen lock **refuses** the
/// change, and never falls back to the app's own PIN.
///
/// UI/UX's spec (7157141241): a full-screen route rather than a dialog, `lock_outline` above the title, info
/// colours because nothing is wrong with the parent, back/cancel returns to the form untouched, and the app PIN
/// is never mentioned here. The copy is theirs, in the seven keys beside this route.
///
/// The one action that keeps working without a lock is signing out, so a parent is never trapped. When they
/// come back from the phone's settings with a lock now set, the same save is repeated with exactly one prompt,
/// so they do not re-enter the change (UI/UX note 1).
class OwnerPresenceScreen extends ConsumerStatefulWidget {
  const OwnerPresenceScreen({super.key});

  @override
  ConsumerState<OwnerPresenceScreen> createState() => _OwnerPresenceScreenState();
}

class _OwnerPresenceScreenState extends ConsumerState<OwnerPresenceScreen> with WidgetsBindingObserver {
  bool _working = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) await _retryWhenLocked();
  }

  /// Repeats the refused save once the phone has a lock. The interceptor asks for the owner once; if the parent
  /// still has not set a lock, nothing happens and this screen stays where it is.
  Future<void> _retryWhenLocked() async {
    if (_working || !mounted) return;
    final prompt = ref.read(ownerPresencePromptProvider);
    if (prompt == null) return;
    if (!await ref.read(ownerPresenceGateProvider).canAsk()) return;
    if (!mounted) return;
    _working = true;
    ref.read(ownerPresencePromptProvider.notifier).state = null;
    context.pop();
    try {
      await ref.read(apiClientProvider).raw.fetch<dynamic>(prompt.pending);
    } catch (_) {
      // The original action already failed visibly; a retry that fails again needs no second report.
    } finally {
      _working = false;
    }
  }

  Future<void> _signOut() async {
    setState(() => _working = true);
    ref.read(ownerPresencePromptProvider.notifier).state = null;
    await ref.read(authProvider.notifier).logout();
    // The router's redirect takes over from here; no explicit navigation, so the auth state stays the source.
  }

  void _close() {
    ref.read(ownerPresencePromptProvider.notifier).state = null;
    if (context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.cancel,
            onPressed: _working ? null : _close,
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Icon(Icons.lock_outline, size: 64, color: scheme.primary),
                const SizedBox(height: 24),
                Text(
                  l10n.ownerPresenceNoLockTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.ownerPresenceNoLockBody,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                TextButton(
                  onPressed: _working ? null : _signOut,
                  child: Text(l10n.ownerPresenceSignOut),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
