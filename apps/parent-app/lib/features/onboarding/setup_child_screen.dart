import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_tokens.dart';
import 'onboarding_messages.dart';

/// Wizard step 2: add the child (name + birth year + the consent the API
/// requires). If the account already has children, the step lists them and
/// continues instead of asking for a duplicate.
class SetupChildScreen extends ConsumerStatefulWidget {
  const SetupChildScreen({super.key});

  @override
  ConsumerState<SetupChildScreen> createState() => _SetupChildScreenState();
}

class _SetupChildScreenState extends ConsumerState<SetupChildScreen> {
  static const _methods = ['sms_plus', 'kba', 'face_match', 'credit_card'];

  final _name = TextEditingController();
  final _birthYear = TextEditingController();
  String _method = _methods.first;
  late String _jurisdiction;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _jurisdiction = ref.read(authProvider).family?.region ?? 'US';
  }

  @override
  void dispose() {
    _name.dispose();
    _birthYear.dispose();
    super.dispose();
  }

  void _continueWithExisting(String childId) {
    ref.read(onboardingProvider.notifier).childAdded(childId);
    context.go('/setup/pair');
  }

  Future<void> _createChild() async {
    final l10n = context.l10n;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.onboardingChildNameRequired);
      return;
    }
    final year = int.tryParse(_birthYear.text.trim());
    final thisYear = DateTime.now().year;
    if (year == null || year < 1900 || year > thisYear) {
      setState(() => _error = l10n.onboardingBirthYearInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post('/v1/family/children', data: {
        'displayName': name,
        'birthYear': year,
        'consent': {'method': _method, 'jurisdiction': _jurisdiction},
      });
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
      final child = data['child'] is Map ? Map<String, dynamic>.from(data['child'] as Map) : const <String, dynamic>{};
      final childId = (child['id'] ?? data['id'])?.toString() ?? '';
      ref.invalidate(familyProvider);
      if (!mounted) return;
      ref.read(onboardingProvider.notifier).childAdded(childId);
      context.go('/setup/pair');
    } on DioException catch (e) {
      if (mounted) setState(() => _error = onboardingChildError(l10n, e));
    } catch (_) {
      if (mounted) setState(() => _error = l10n.onboardingChildFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A way back without a dead end: sign out and return to the sign-in step.
  /// Progress already saved on the server stays on the account.
  Future<void> _leaveSetup() async {
    final l10n = context.l10n;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.onboardingLeaveTitle),
        content: Text(l10n.onboardingLeaveBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.onboardingLeaveStay)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.onboardingLeaveConfirm)),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    await ref.read(authProvider.notifier).logout();
    await ref.read(onboardingProvider.notifier).backToSignIn();
    if (mounted) context.go('/sign-in');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final family = ref.watch(familyProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.onboardingChildTitle),
        leading: BackButton(onPressed: _busy ? null : _leaveSetup),
      ),
      body: SafeArea(
        child: family.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _LoadFailed(
            message: l10n.onboardingNoNetwork,
            onRetry: () => ref.invalidate(familyProvider),
          ),
          data: (overview) => overview.children.isEmpty
              ? _buildForm(context, l10n)
              : _buildExisting(context, l10n, overview.children),
        ),
      ),
    );
  }

  Widget _buildExisting(BuildContext context, AppLocalizations l10n, List<Child> children) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(l10n.onboardingExistingChildren, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: AppSpace.md),
        for (final child in children)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(child.initials)),
              title: Text(child.displayName),
              subtitle: Text('${child.birthYear}'),
            ),
          ),
        const SizedBox(height: AppSpace.lg),
        FilledButton.icon(
          key: const ValueKey('onboardingExistingContinue'),
          onPressed: () => _continueWithExisting(children.first.id),
          icon: const Icon(Icons.arrow_forward),
          label: Text(l10n.continueLabel),
        ),
      ],
    );
  }

  Widget _buildForm(BuildContext context, AppLocalizations l10n) {
    final tokens = context.tokens;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(
          l10n.onboardingChildIntro,
          key: const ValueKey('onboardingChildIntro'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          key: const ValueKey('onboardingChildName'),
          controller: _name,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.childNameLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        TextField(
          key: const ValueKey('onboardingBirthYear'),
          controller: _birthYear,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.birthYearLabel,
            hintText: '${DateTime.now().year}',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        Text(l10n.parentalConsent, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        // TODO(#159): legal consent wording needs a product/legal decision
        // before it can be translated; it stays English, as on the dashboard.
        Text(l10n.consentNotice, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppSpace.md),
        DropdownButtonFormField<String>(
          key: const ValueKey('onboardingConsentMethod'),
          initialValue: _method,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.consentMethodLabel, border: const OutlineInputBorder()),
          items: [for (final m in _methods) DropdownMenuItem(value: m, child: Text(l10n.consentMethod(m)))],
          onChanged: _busy ? null : (v) => setState(() => _method = v ?? _methods.first),
        ),
        const SizedBox(height: AppSpace.md),
        DropdownButtonFormField<String>(
          key: const ValueKey('onboardingJurisdiction'),
          initialValue: _jurisdiction,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.jurisdictionLabel, border: const OutlineInputBorder()),
          items: [
            DropdownMenuItem(value: 'US', child: Text(l10n.regionUS)),
            DropdownMenuItem(value: 'EU', child: Text(l10n.regionEU)),
            DropdownMenuItem(value: 'UK', child: Text(l10n.regionUK)),
            DropdownMenuItem(value: 'OTHER', child: Text(l10n.regionOther)),
          ],
          onChanged: _busy ? null : (v) => setState(() => _jurisdiction = v ?? 'US'),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(
            _error!,
            key: const ValueKey('onboardingChildError'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        FilledButton(
          key: const ValueKey('onboardingAddChild'),
          onPressed: _busy ? null : _createChild,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.onboardingAddChildContinue),
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          l10n.onboardingChildPrivacy,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: context.tokens.danger),
            const SizedBox(height: AppSpace.md),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpace.md),
            FilledButton.tonal(onPressed: onRetry, child: Text(context.l10n.tryAgain)),
          ],
        ),
      ),
    );
  }
}
