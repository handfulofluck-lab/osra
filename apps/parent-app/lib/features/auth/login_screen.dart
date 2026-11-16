import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/digits.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/server_provider.dart';
import '../../theme/app_tokens.dart';
import '../onboarding/onboarding_messages.dart';
import 'auth_messages.dart';
import 'create_account_screen.dart';
import 'mfa_recovery_screen.dart';

/// Sign-in screen with an expandable registration form. Navigation after a
/// successful login/register is handled by the router's auth redirect.
///
/// [onboarding] is the first-run wizard's account step: it adds a back route
/// to Welcome and names the causes a non-engineer can fix (wrong password,
/// unreachable server) instead of showing the API's raw code.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.onboarding = false, this.debug, this.builtIn});

  final bool onboarding;

  /// Test seam: overrides [kDebugMode] for the server-field visibility check. Production leaves it null.
  final bool? debug;

  /// Test seam: overrides [kDefaultServerUrl] for the server-field lock/visibility check. Production
  /// leaves it null. [_LoginScreenState._saveServer] does not read it: the effective server is never
  /// driven by the widget.
  final String? builtIn;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _obscured = true;
  bool _serverTouched = false;
  String? _serverError;

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
    super.dispose();
  }

  /// Validates and persists the server URL; null → inline error, abort submit.
  Future<String?> _saveServer() async {
    // osra-security#8 F3: a build with the server built in uses it; the field is locked and never read.
    final builtIn = builtInServerUrl();
    if (builtIn != null) return builtIn;
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

  bool _titleFitsInAppBar(BuildContext context, String title, {required bool canGoBack}) {
    final availableWidth = (MediaQuery.sizeOf(context).width - (canGoBack ? 72 : 32) - 16)
        .clamp(0.0, double.infinity);
    final painter = TextPainter(
      text: TextSpan(
        text: title,
        style: Theme.of(context).appBarTheme.titleTextStyle ?? Theme.of(context).textTheme.titleLarge,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
    )..layout(maxWidth: availableWidth);
    return !painter.didExceedMaxLines;
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
    final titleInAppBar = widget.onboarding &&
        _titleFitsInAppBar(context, l10n.onboardingSignInTitle, canGoBack: canGoBack);
    final backButton = canGoBack
        ? BackButton(onPressed: () {
            ref.read(onboardingProvider.notifier).backToWelcome();
            context.go('/welcome');
          })
        : null;
    // Keep the field in sync with the persisted URL until the user edits it.
    if (!_serverTouched && _server.text != serverUrl) {
      _server.text = serverUrl;
    }
    final errorText = _authErrorText(l10n, auth.error);
    final builtIn = widget.builtIn ?? kDefaultServerUrl;
    final locked = isServerLocked(builtIn);
    final showServer = showServerField(debug: widget.debug ?? kDebugMode, builtIn: builtIn);
    return Scaffold(
      appBar: widget.onboarding
          ? (titleInAppBar
              ? AppBar(
                  toolbarHeight: MediaQuery.textScalerOf(context).scale(kToolbarHeight + AppSpace.sm),
                  title: Text(
                    l10n.onboardingSignInTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: backButton,
                )
              : AppBar(leading: backButton))
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
                  if (!titleInAppBar) ...[
                    const SizedBox(height: AppSpace.md),
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.onboardingSignInTitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
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
                if (showServer) ...[
                  TextField(
                    key: const ValueKey('loginServerField'),
                    controller: _server,
                    // osra-security#8 F3: hidden in locked (store) builds; debug keeps it visible and locked.
                    readOnly: locked,
                    enabled: !locked,
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
                ],
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
                    helperText: l10n.mfaCodeHelper,
                    helperMaxLines: 2,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                  ),
                ),
                if (errorText != null) ...[
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
                          if (await _saveServer() == null) return;
                          await _submit(() => ref.read(authProvider.notifier).login(_email.text.trim(), _password.text, normalizeDigits(_code.text)));
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
                TextButton(
                  key: const ValueKey('openCreateAccount'),
                  // ADR-0043 D6 (UI/UX Bureau): sign-up is its own page, opened from one line here,
                  // not an expansion tile that also holds someone else's sign-in error.
                  onPressed: () async {
                    // The server is applied before the page opens, exactly as Sign in does: the page's
                    // consent read must not go to an empty base URL on an unlocked build.
                    if (await _saveServer() == null) return;
                    if (!context.mounted) return;
                    await Navigator.of(context).push<void>(MaterialPageRoute(
                      builder: (_) => CreateAccountScreen(onboarding: widget.onboarding),
                    ));
                  },
                  child: Text(l10n.createAccount),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
