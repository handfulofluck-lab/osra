import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/permission_errors.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'consent_step.dart';

const kChildAgeMin = 1;
const kChildAgeMax = 17;

final p04AddChildEnabledProvider = Provider<bool>(
  (_) => const bool.fromEnvironment('OSRA_UX_P04', defaultValue: false),
);

class AddChildP04Screen extends ConsumerWidget {
  const AddChildP04Screen({super.key, required this.jurisdiction});

  final String jurisdiction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.p04AddTitle)),
      body: SafeArea(
        child: AddChildP04Form(
          jurisdiction: jurisdiction,
          onCreated: (_) => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}

class AddChildP04Form extends ConsumerStatefulWidget {
  const AddChildP04Form({
    super.key,
    required this.jurisdiction,
    required this.onCreated,
  });

  final String jurisdiction;
  final ValueChanged<String> onCreated;

  @override
  ConsumerState<AddChildP04Form> createState() => _AddChildP04FormState();
}

class _AddChildP04FormState extends ConsumerState<AddChildP04Form> {
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _nameFocus = FocusNode();
  final _ageFocus = FocusNode();
  final _consentFocus = FocusNode();
  final _consentTileKey = GlobalKey();
  String _method = kConsentMethods.first;
  bool _affirmed = false;
  bool _busy = false;
  String? _nameError;
  String? _ageError;
  String? _consentError;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_validateNameOnBlur);
    _ageFocus.addListener(_validateAgeOnBlur);
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _nameFocus.dispose();
    _ageFocus.dispose();
    _consentFocus.dispose();
    super.dispose();
  }

  void _validateNameOnBlur() {
    if (_nameFocus.hasFocus || !mounted) return;
    setState(() {
      _nameError = _name.text.trim().isEmpty
          ? context.l10n.onboardingChildNameRequired
          : null;
    });
  }

  void _validateAgeOnBlur() {
    if (_ageFocus.hasFocus || !mounted) return;
    final age = int.tryParse(normalizeDigits(_age.text.trim()));
    setState(() {
      _ageError = age == null || age < kChildAgeMin || age > kChildAgeMax
          ? context.l10n.p04AgeRange(
              ltrIsolate('$kChildAgeMin'), ltrIsolate('$kChildAgeMax'))
          : null;
    });
  }

  void _showCollected() {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.onboardingChildPrivacy),
              const SizedBox(height: AppSpace.md),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: Text(l10n.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createChild() async {
    if (_busy) return;
    final l10n = context.l10n;
    final name = _name.text.trim();
    final age = int.tryParse(normalizeDigits(_age.text.trim()));
    final thisYear = ref.read(clockProvider)().year;
    setState(() {
      _nameError = name.isEmpty ? l10n.onboardingChildNameRequired : null;
      _ageError = age == null || age < kChildAgeMin || age > kChildAgeMax
          ? l10n.p04AgeRange(
              ltrIsolate('$kChildAgeMin'), ltrIsolate('$kChildAgeMax'))
          : null;
      _consentError = _affirmed ? null : l10n.p04GuardianRequired;
      _submitError = null;
    });
    if (_nameError != null || _ageError != null) return;
    if (!_affirmed) {
      _consentFocus.requestFocus();
      final tile = _consentTileKey.currentContext;
      if (tile != null) Scrollable.ensureVisible(tile);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiClientProvider).raw.post(
        '/v1/family/children',
        data: {
          'displayName': name,
          'birthYear': thisYear - age!,
          'consent': {'method': _method, 'jurisdiction': widget.jurisdiction},
        },
      );
      final data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : const <String, dynamic>{};
      final child = data['child'] is Map
          ? Map<String, dynamic>.from(data['child'] as Map)
          : const <String, dynamic>{};
      final childId = (child['id'] ?? data['id'])?.toString() ?? '';
      if (childId.isEmpty) throw const FormatException('child id missing');
      ref.invalidate(familyProvider);
      if (mounted) widget.onCreated(childId);
    } on DioException catch (e) {
      if (mounted) {
        setState(() => _submitError =
            friendlyErrorText(l10n, e, () => l10n.onboardingChildFailed));
      }
    } catch (_) {
      if (mounted) setState(() => _submitError = l10n.onboardingChildFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        TextField(
          key: const ValueKey('p04ChildName'),
          controller: _name,
          focusNode: _nameFocus,
          textInputAction: TextInputAction.next,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          decoration: InputDecoration(
            labelText: l10n.childNameLabel,
            errorText: _nameError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        TextField(
          key: const ValueKey('p04ChildAge'),
          controller: _age,
          focusNode: _ageFocus,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_ageError != null) setState(() => _ageError = null);
          },
          onSubmitted: (_) => _createChild(),
          decoration: InputDecoration(
            labelText: l10n.p04AgeRange(
                ltrIsolate('$kChildAgeMin'), ltrIsolate('$kChildAgeMax')),
            errorText: _ageError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        ConsentStep(
          method: _method,
          onMethodChanged: (method) => setState(() => _method = method),
        ),
        const SizedBox(height: AppSpace.md),
        CheckboxListTile(
          key: _consentTileKey,
          focusNode: _consentFocus,
          value: _affirmed,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          onChanged: _busy
              ? null
              : (value) => setState(() {
                    _affirmed = value ?? false;
                    if (_affirmed) _consentError = null;
                  }),
          title: Text(l10n.p04GuardianConfirm),
        ),
        if (_consentError != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Text(
                _consentError!,
                key: const ValueKey('p04ConsentError'),
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: tokens.danger),
              ),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('p04CollectedLink'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: tokens.primary,
            ),
            onPressed: _showCollected,
            child: Text(l10n.p04WhatWeCollect),
          ),
        ),
        if (_submitError != null) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            _submitError!,
            key: const ValueKey('p04SubmitError'),
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: tokens.danger),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        FilledButton(
          key: const ValueKey('p04Submit'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _createChild,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.addChild, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}
