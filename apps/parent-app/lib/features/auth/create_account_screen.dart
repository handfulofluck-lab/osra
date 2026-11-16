import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/mfa_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_tokens.dart';
import 'auth_messages.dart';
import 'consent_copy.dart';

/// ADR-0043 D6, part B: the sign-up page with its one required consent choice.
///
/// The page exists on its own because a parent should see what they agree to on a page made for it, not
/// inside a fold that also holds someone else's sign-in error (UI/UX Bureau). The consent sentence and its
/// links come from `GET /v1/consent-copy`; this file carries no legal text. The two links are buttons under
/// the row, so a tap meant for a link can never tick the box.
class CreateAccountScreen extends ConsumerStatefulWidget {
  const CreateAccountScreen({super.key, this.onboarding = false});

  /// Opened from the first-run wizard's account step: after a successful register the wizard advances to
  /// its child step, exactly as LoginScreen does for sign-in.
  final bool onboarding;

  @override
  ConsumerState<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends ConsumerState<CreateAccountScreen> {
  final _familyName = TextEditingController();
  final _displayName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _consentTileKey = GlobalKey();
  final _consentFocus = FocusNode();

  String _region = 'US';
  bool _accepted = false;
  bool _consentMissing = false;
  bool _submitting = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    // R-ID-1: a failed sign-in on the previous screen must not render here before this form has asked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(authProvider.notifier).clearError();
    });
  }

  @override
  void dispose() {
    _consentFocus.dispose();
    _familyName.dispose();
    _displayName.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    // Only https: a response cannot steer the app into intent:, file: or cleartext.
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) return;
    await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  }

  Future<void> _submit(ConsentCopy copy, ConsentPurpose purpose) async {
    final l10n = context.l10n;
    final problem = registerFormProblem(
      l10n,
      email: _email.text.trim(),
      password: _password.text,
      displayName: _displayName.text.trim(),
      familyName: _familyName.text.trim(),
    );
    setState(() {
      _formError = problem;
      _consentMissing = !_accepted;
    });
    if (problem != null) return;
    if (_consentMissing) {
      // The error is a line under the box and focus lands on the box: no dialog, no snackbar. The node is
      // owned by this state and attached to the tile, so the focus actually moves (WCAG 3.3.1).
      _consentFocus.requestFocus();
      final tile = _consentTileKey.currentContext;
      if (tile != null) Scrollable.ensureVisible(tile);
      return;
    }
    setState(() => _submitting = true);
    await ref.read(authProvider.notifier).register(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _displayName.text.trim(),
          familyName: _familyName.text.trim(),
          region: _region,
          consentTextVersion: copy.textVersion,
          consentLocale: Localizations.localeOf(context).languageCode,
        );
    if (!mounted) return;
    final error = ref.read(authProvider).error;
    if (error == 'consent_text_outdated') {
      // The wording changed under us. Untick, drop the cached copy and ask again against the new version;
      // the server's code is never shown (R-ID-1).
      ref.read(authProvider.notifier).clearError();
      ref.invalidate(consentCopyProvider(Localizations.localeOf(context).languageCode));
      setState(() {
        _submitting = false;
        _accepted = false;
        _consentMissing = true;
      });
      return;
    }
    if (ref.read(authProvider).isAuthenticated) {
      if (widget.onboarding) ref.read(onboardingProvider.notifier).signedIn();
      ref.read(loginNoticeProvider.notifier).state = null;
    }
    setState(() => _submitting = false);
  }

  /// UI/UX item 2 on #846: a 48 dp target, brand primary, underlined — a link a parent can see is a link.
  static ButtonStyle consentLinkStyle(BuildContext context) {
    final tokens = context.tokens;
    return TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: tokens.primary,
      textStyle: const TextStyle(decoration: TextDecoration.underline),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final auth = ref.watch(authProvider);
    final locale = Localizations.localeOf(context).languageCode;
    final copy = ref.watch(consentCopyProvider(locale));
    final providerError = authErrorText(l10n, auth.error);
    final shownError = _formError ?? providerError;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.createAccount)),
      body: SafeArea(
        child: copy.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.onboardingNoNetwork, textAlign: TextAlign.center),
                  const SizedBox(height: AppSpace.md),
                  TextButton(
                    key: const ValueKey('consentRetry'),
                    onPressed: () => ref.invalidate(consentCopyProvider(locale)),
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            ),
          ),
          data: (data) {
            final purpose = data.termsPrivacy;
            if (purpose == null) {
              // A copy without the required purpose is not something a parent can accept: say so and let
              // them retry, never a permission sentence that means nothing on this screen.
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.onboardingNoNetwork, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpace.md),
                      TextButton(
                        onPressed: () => ref.invalidate(consentCopyProvider(locale)),
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              );
            }
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.lg, AppSpace.xl, AppSpace.xl + MediaQuery.viewInsetsOf(context).bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: l10n.emailLabel,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.passwordLabel,
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
                  const SizedBox(height: AppSpace.lg),
                  CheckboxListTile(
                    key: _consentTileKey,
                    focusNode: _consentFocus,
                    value: _accepted,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() {
                      _accepted = v ?? false;
                      if (_accepted) _consentMissing = false;
                    }),
                    title: Text(purpose.plainText, key: const ValueKey('consentTermsText')),
                  ),
                  // The links sit under the row, not inside it: a tap meant for a link must never tick the
                  // box (UI/UX Bureau). Their words come from the copy's own markdown, so no legal or
                  // Arabic string is authored here.
                  Wrap(
                    spacing: AppSpace.md,
                    children: [
                      if (purpose.termsLabel.isNotEmpty)
                        TextButton(
                          key: const ValueKey('consentTermsLink'),
                          style: consentLinkStyle(context),
                          onPressed: () => _openLink(purpose.termsUrl),
                          child: Text(purpose.termsLabel),
                        ),
                      if (purpose.privacyLabel.isNotEmpty)
                        TextButton(
                          key: const ValueKey('consentPrivacyLink'),
                          style: consentLinkStyle(context),
                          onPressed: () => _openLink(purpose.privacyUrl),
                          child: Text(purpose.privacyLabel),
                        ),
                    ],
                  ),
                  if (_consentMissing)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, size: 18, color: tokens.danger),
                            const SizedBox(width: AppSpace.sm),
                            Expanded(
                              child: Text(
                                l10n.consentRequired,
                                key: const ValueKey('consentError'),
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (shownError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.sm),
                      child: Text(
                        shownError,
                        key: const ValueKey('registerError'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.danger),
                      ),
                    ),
                  const SizedBox(height: AppSpace.md),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      key: const ValueKey('createAccountButton'),
                      // Never greyed out: the box's error is the answer, not a disabled button.
                      onPressed: auth.loading || _submitting ? null : () => _submit(data, purpose),
                      child: Text(l10n.createAccount),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
