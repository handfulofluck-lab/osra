import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
import '../../providers/server_provider.dart';

/// Sign-in screen with an expandable registration form. Navigation after a
/// successful login/register is handled by the router's auth redirect.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

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
    setState(() => _serverError = url == null ? 'Enter a valid server, e.g. http://192.168.1.5:3000' : null);
    if (url == null) return null;
    await ref.read(serverUrlProvider.notifier).setServerUrl(url);
    return url;
  }

  Future<void> _submit(Future<void> Function() action) async {
    await action();
    if (mounted && ref.read(authProvider).isAuthenticated) {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    // Keep the field in sync with the persisted URL until the user edits it.
    if (!_serverTouched && _server.text != serverUrl) {
      _server.text = serverUrl;
    }
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shield_outlined, size: 72),
                const SizedBox(height: 8),
                Text('OSRA', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text('أسرة — parental control for your family',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                // The current server is shown only once one has been entered and
                // saved — a fresh install shows no server name at all.
                if (serverUrl.isNotEmpty) ...[
                  Text('Server: $serverUrl',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 24),
                ] else
                  const SizedBox(height: 24),
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autofillHints: const [AutofillHints.url],
                  onChanged: (_) => _serverTouched = true,
                  decoration: InputDecoration(
                    labelText: 'Server',
                    hintText: 'http://host:port',
                    errorText: _serverError,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: _obscured,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscured = !_obscured),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(
                    labelText: 'Authentication code (if MFA is on)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (auth.error != null) ...[
                  const SizedBox(height: 12),
                  Text(auth.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: auth.loading
                      ? null
                      : () async {
                          if (await _saveServer() == null) return;
                          await _submit(() => ref.read(authProvider.notifier).login(_email.text.trim(), _password.text, _code.text));
                        },
                  icon: auth.loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
                const SizedBox(height: 8),
                ExpansionTile(
                  title: const Text('Create account'),
                  childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    TextField(
                      controller: _familyName,
                      decoration: const InputDecoration(labelText: 'Family name', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _displayName,
                      decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _region,
                      decoration: const InputDecoration(labelText: 'Region', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'US', child: Text('United States')),
                        DropdownMenuItem(value: 'EU', child: Text('European Union')),
                        DropdownMenuItem(value: 'UK', child: Text('United Kingdom')),
                        DropdownMenuItem(value: 'OTHER', child: Text('Other')),
                      ],
                      onChanged: (v) => setState(() => _region = v ?? 'US'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: auth.loading
                          ? null
                          : () async {
                              if (await _saveServer() == null) return;
                              await _submit(() => ref.read(authProvider.notifier).register(
                                    email: _email.text.trim(),
                                    password: _password.text,
                                    displayName: _displayName.text.trim(),
                                    familyName: _familyName.text.trim(),
                                    region: _region,
                                  ));
                            },
                      child: const Text('Register'),
                    ),
                    const SizedBox(height: 16),
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
