import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/server_provider.dart';
import '../../theme/app_tokens.dart';
import '../onboarding/onboarding_messages.dart';
import 'auth_messages.dart';
import 'mfa_recovery_screen.dart';

/// Sign-in screen with an expandable registration form. Navigation after a
/// successful login/register is handled by the router's auth redirect.
///
/// [onboarding] is the first-run wizard's account step: it adds a back route
/// to Welcome and names the causes a non-engineer can fix (wrong password,
/// unreachable server) instead of showing the API's raw code.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.onboarding = false});

  final bool onboarding;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _displayName = TextEditingController();
  final _familyName = TextEditingController();
  bool _obscured = true;
  bool _serverTouched = false;
  String? _serverError;
  String _region = 'US';

  /// A register-form problem caught before the request (see [registerFormProblem]).
  String? _formError;

  /// The last button pressed was Register, so its error shows beside that button, inside the
  /// expanded section, rather than above Sign in where a parent filling the form cannot see it.
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _server.text = ref.read(serverUrlProvider);
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _displayName.dispose();
    _familyName.dispose();
    super.dispose();
  }

  /// Validates and persists the server URL; null → inline error, abort submit.
  Future<String?> _saveServer() async {
    final url = normalizeServerUrl(_server.text);
    setState(() => _serverError = url == null ? context.l10n.invalidServer : null);
    if (url == null) return null;
    await ref.read(serverUrlProvider.notifier).setServerUrl(url);
    return url;
  }

  /// What the parent reads for [AuthState.error]. A rejected field and a taken email are named on
  /// both screens; anything else keeps the existing split (the wizard names the causes a
  /// non-engineer can fix, the plain screen shows the server's string).
  String? _authErrorText(AppLocalizations l10n, String? raw) {
    if (raw == null) return null;
    if (raw.startsWith(kValidationFailedPrefix)) return authFieldError(l10n, raw);
    if (raw == 'email_taken') return l10n.registerEmailTaken;
    return widget.onboarding ? onboardingAuthError(l10n, raw) : raw;
  }

  Future<void> _submit(Future<void> Function() action) async {
    await action();
    if (mounted && ref.read(authProvider).isAuthenticated) {
      if (widget.onboarding) {
        // Save the next step before navigating so a kill here resumes at the
        // child step rather than replaying sign-in.
        ref.read(onboardingProvider.notifier).signedIn();
      }
      ref.read(loginNoticeProvider.notifier).state = null;
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final auth = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    final showMfaNotice = ref.watch(loginNoticeProvider) == kLoginNoticeMfaSessionEnded;
    final l10n = context.l10n;
    final onboarding = ref.watch(onboardingProvider);
    final canGoBack = widget.onboarding &&
        (onboarding.step == OnboardingStep.signIn || onboarding.step == OnboardingStep.welcome);
    // Keep the field in sync with the persisted URL until the user edits it.
    if (!_serverTouched && _server.text != serverUrl) {
      _server.text = serverUrl;
    }
    final errorText = _formError ?? _authErrorText(l10n, auth.error);
    return Scaffold(
      appBar: widget.onboarding
          ? AppBar(
              title: Text(l10n.onboardingSignInTitle),
              leading: canGoBack
                  ? BackButton(onPressed: () {
                      ref.read(onboardingProvider.notifier).backToWelcome();
                      context.go('/welcome');
                    })
                  : null,
            )
          : null,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: ConstrainedBox(
            // 420 px is the form's reading width, not a gap on the scale.
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shield_outlined, size: 72),
                const SizedBox(height: AppSpace.sm),
                Text('OSRA', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: AppSpace.xs),
                Text(l10n.appTagline,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant)),
                if (widget.onboarding) ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    l10n.onboardingSignInBody,
                    key: const ValueKey('onboardingSignInBody'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
                // The current server is shown only once one has been entered and
                // saved — a fresh install shows no server name at all.
                if (serverUrl.isNotEmpty) ...[
                  Text(l10n.serverShown(serverUrl),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant)),
                  const SizedBox(height: AppSpace.xl),
                ] else
                  const SizedBox(height: AppSpace.xl),
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autofillHints: const [AutofillHints.url],
                  onChanged: (_) => _serverTouched = true,
                  decoration: InputDecoration(
                    labelText: l10n.serverLabel,
                    hintText: l10n.serverHint,
                    errorText: _serverError,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                if (showMfaNotice) ...[
                  Text(
                    l10n.mfaSessionNotice,
                    key: const ValueKey('loginMfaNotice'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: tokens.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpace.md),
                ],
                TextField(
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
                ),
                const SizedBox(height: AppSpace.md),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: InputDecoration(
                    labelText: l10n.mfaCodeLabel,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                  ),
                ),
                if (errorText != null && !_registering) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(errorText,
                      key: const ValueKey('loginError'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger)),
                ],
                const SizedBox(height: AppSpace.lg),
                FilledButton.icon(
                  onPressed: auth.loading
                      ? null
                      : () async {
                          setState(() {
                            _registering = false;
                            _formError = null;
                          });
                          if (await _saveServer() == null) return;
                          await _submit(() => ref.read(authProvider.notifier).login(_email.text.trim(), _password.text, _code.text));
                        },
                  icon: auth.loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login),
                  label: Text(l10n.signIn),
                ),
                const SizedBox(height: AppSpace.xs),
                TextButton(
                  key: const ValueKey('lostAuthenticator'),
                  onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
                    builder: (_) => const MfaRecoveryScreen(),
                  )),
                  child: Text(l10n.mfaRecoveryLink),
                ),
                const SizedBox(height: AppSpace.sm),
                ExpansionTile(
                  title: Text(l10n.createAccount),
                  childrenPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  children: [
                    // The section has no email or password of its own; say so, with the rule the
                    // server enforces, before the parent finds out from an error.
                    Text(
                      l10n.registerFieldsHint,
                      key: const ValueKey('registerFieldsHint'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpace.md),
                    TextField(
                      controller: _familyName,
                      decoration: InputDecoration(
                        labelText: l10n.familyNameLabel,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    TextField(
                      controller: _displayName,
                      decoration: InputDecoration(
                        labelText: l10n.yourNameLabel,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    DropdownButtonFormField<String>(
                      initialValue: _region,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.regionLabel,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                      ),
                      items: [
                        DropdownMenuItem(value: 'US', child: Text(l10n.regionUS)),
                        DropdownMenuItem(value: 'EU', child: Text(l10n.regionEU)),
                        DropdownMenuItem(value: 'UK', child: Text(l10n.regionUK)),
                        DropdownMenuItem(value: 'OTHER', child: Text(l10n.regionOther)),
                      ],
                      onChanged: (v) => setState(() => _region = v ?? 'US'),
                    ),
                    const SizedBox(height: AppSpace.md),
                    if (errorText != null && _registering) ...[
                      Text(errorText,
                          key: const ValueKey('registerError'),
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger)),
                      const SizedBox(height: AppSpace.md),
                    ],
                    OutlinedButton(
                      onPressed: auth.loading
                          ? null
                          : () async {
                              final problem = registerFormProblem(
                                l10n,
                                email: _email.text.trim(),
                                password: _password.text,
                                displayName: _displayName.text.trim(),
                                familyName: _familyName.text.trim(),
                              );
                              setState(() {
                                _registering = true;
                                _formError = problem;
                              });
                              if (problem != null) return;
                              if (await _saveServer() == null) return;
                              await _submit(() => ref.read(authProvider.notifier).register(
                                    email: _email.text.trim(),
                                    password: _password.text,
                                    displayName: _displayName.text.trim(),
                                    familyName: _familyName.text.trim(),
                                    region: _region,
                                  ));
                            },
                      child: Text(l10n.register),
                    ),
                    const SizedBox(height: AppSpace.lg),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
