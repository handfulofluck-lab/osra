import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/permission_errors.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart' show apiClientProvider, authProvider;
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// The server's rule for a new password (register, reset and change all use it).
const int minPasswordLength = 12;

/// The sentence for a refusal from `POST /v1/auth/password`, so a code never reaches the parent.
String changePasswordError(AppLocalizations l10n, DioException e) {
  final status = e.response?.statusCode;
  final body = e.response?.data;
  final code = body is Map ? body['error'] : null;
  if (status == 429) return l10n.cpRateLimited;
  return switch (code) {
    'invalid_credentials' => l10n.cpWrongCurrent,
    'mfa_required' => l10n.cpCodeNeeded,
    'password_unchanged' => l10n.cpSame,
    _ => status == 400 ? l10n.cpNewHint : friendlyErrorText(l10n, e, () => l10n.cpFailed),
  };
}

/// #716: change the password while signed in.
///
/// The server checks the current password (and a code when two-step sign-in is on), ends every session
/// and returns a fresh token pair for this device, which is stored before anything else is requested.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  final _code = TextEditingController();
  bool _obscured = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    _code.dispose();
    super.dispose();
  }

  bool _ready(bool mfa) =>
      _current.text.isNotEmpty &&
      _next.text.length >= minPasswordLength &&
      _again.text.isNotEmpty &&
      (!mfa || _code.text.trim().isNotEmpty);

  Future<void> _submit(bool mfa) async {
    if (_busy || !_ready(mfa)) return;
    final l10n = context.l10n;
    if (_next.text != _again.text) {
      setState(() => _error = l10n.cpMismatch);
      return;
    }
    if (_next.text == _current.text) {
      setState(() => _error = l10n.cpSame);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post('/v1/auth/password', data: {
        'currentPassword': _current.text,
        'newPassword': _next.text,
        if (mfa) 'code': _code.text.trim(),
      });
      final data = res.data is Map ? res.data as Map : const <String, dynamic>{};
      final token = data['token'];
      if (token is! String || token.isEmpty) throw const FormatException('password change missing token');
      await ref.read(authProvider.notifier).adoptSession(token, data['refreshToken'] as String?);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l10n.cpDone)));
      if (context.canPop()) context.pop();
    } on DioException catch (e) {
      if (!mounted) return;
      logParentError(e);
      setState(() {
        _busy = false;
        _error = changePasswordError(l10n, e);
      });
    } catch (e) {
      if (!mounted) return;
      logParentError(e);
      setState(() {
        _busy = false;
        _error = l10n.cpFailed;
      });
    }
  }

  Widget _field(String key, TextEditingController c, String label, {String? helper, bool secret = true}) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: TextField(
        key: ValueKey(key),
        controller: c,
        enabled: !_busy,
        obscureText: secret && _obscured,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: secret ? TextInputType.visiblePassword : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
          suffixIcon: secret
              ? IconButton(
                  tooltip: _obscured ? l10n.showPassword : l10n.hidePassword,
                  icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscured = !_obscured),
                )
              : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mfa = ref.watch(familyProvider).valueOrNull?.parent.mfaEnabled ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.changePasswordMenu)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(l10n.cpIntro, key: const ValueKey('cpIntro'), style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpace.lg),
          _field('cpCurrent', _current, l10n.cpCurrent),
          _field('cpNew', _next, l10n.cpNew, helper: l10n.cpNewHint),
          _field('cpAgain', _again, l10n.cpConfirm),
          if (mfa) _field('cpCode', _code, l10n.cpCode, helper: l10n.cpCodeHint, secret: false),
          if (_error != null) ...[
            Text(_error!, key: const ValueKey('cpError'), style: TextStyle(color: context.tokens.danger)),
            const SizedBox(height: AppSpace.sm),
          ],
          FilledButton(
            key: const ValueKey('cpSubmit'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: (_busy || !_ready(mfa)) ? null : () => _submit(mfa),
            child: Text(_busy ? l10n.cpBusy : l10n.changePasswordMenu),
          ),
        ],
      ),
    );
  }
}
