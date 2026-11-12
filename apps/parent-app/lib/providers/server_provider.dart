import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import 'auth_provider.dart';

/// Default API base used when no server URL is persisted. Intentionally blank:
/// the server must be typed at first launch (testers enter their own tunnel/LAN
/// address), never pre-filled with a stale or built-in URL.
const kDefaultServerUrl = String.fromEnvironment('API_BASE', defaultValue: '');

/// shared_preferences key for the persisted server URL override.
const kServerUrlKey = 'server_url';

/// Normalizes a user-entered server URL: trims whitespace, strips trailing slashes and
/// prepends `http://` when the scheme is missing (BUG-006 — testers type `192.168.1.5:3000`,
/// which the Android agent already accepts). Returns null unless the result matches
/// `http(s)://host[:port][/path]` with a word/dot/hyphen host (IPs and LAN hostnames
/// such as `testserver` or `my-server.local` — hyphens included, pinned by the BUG-006 tests).
String? normalizeServerUrl(String input) {
  var url = input.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  if (url.isEmpty) return null;
  // Scheme-less input: default to plain http (LAN/test backends are http behind a tunnel).
  if (!url.contains('://')) url = 'http://$url';
  if (!RegExp(r'^https?://[\w.-]+(:\d+)?(/\S*)?$', caseSensitive: false).hasMatch(url)) return null;
  return url;
}

/// osra-security#8 F3, the child's rule from #553: a build with `API_BASE` built in (the store builds) talks to
/// that server only. The login screen shows it locked, a typed or previously saved URL is ignored, and a wake
/// uses it too, so nobody can talk a parent into sending their email and password to another host. Builds
/// without it (local testing) keep the editable field exactly as before.
String? builtInServerUrl([String builtIn = kDefaultServerUrl]) => normalizeServerUrl(builtIn);

/// Whether the server field is locked to [builtInServerUrl].
bool isServerLocked([String builtIn = kDefaultServerUrl]) => builtInServerUrl(builtIn) != null;

/// The server to use: the built-in one when there is one, else the saved one, else empty.
String effectiveServerUrl({String? saved, String builtIn = kDefaultServerUrl}) =>
    builtInServerUrl(builtIn) ?? normalizeServerUrl(saved ?? '') ?? '';

/// Effective server URL ([effectiveServerUrl]: the built-in server, else the persisted one).
final serverUrlProvider = StateNotifierProvider<ServerUrlNotifier, String>((ref) {
  final notifier = ServerUrlNotifier(ref.watch(apiClientProvider));
  notifier.load();
  return notifier;
});

/// Holds the effective server URL and points the shared Dio client at it.
class ServerUrlNotifier extends StateNotifier<String> {
  final ApiClient _api;
  final String _builtIn;

  ServerUrlNotifier(this._api, {String builtIn = kDefaultServerUrl})
      : _builtIn = builtIn,
        super(effectiveServerUrl(builtIn: builtIn));

  Future<void>? _loading;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Loads the persisted URL (if any) and applies it to the Dio client.
  void load() {
    _loading ??= _loadInner().whenComplete(() => _loading = null);
  }

  Future<void> _loadInner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = effectiveServerUrl(saved: prefs.getString(kServerUrlKey), builtIn: _builtIn);
      if (!_disposed && next.isNotEmpty) state = next;
    } catch (_) {
      // prefs unavailable (e.g. tests) — keep the define default
    }
    if (!_disposed) apply();
  }

  /// Persists [url] (normalized) and applies it to the shared Dio client.
  /// Invalid input is ignored, keeping the current URL, and so is any input in a locked build.
  Future<void> setServerUrl(String url) async {
    // F3: a locked build never changes server, whatever is typed.
    if (isServerLocked(_builtIn)) return;
    final normalized = normalizeServerUrl(url);
    if (normalized == null) return;
    state = normalized;
    apply();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kServerUrlKey, normalized);
    } catch (_) {}
  }

  /// Points the shared Dio client at the current URL (idempotent).
  void apply() {
    if (_disposed) return;
    _api.raw.options.baseUrl = state;
  }

  /// Waits for the initial [load] to finish, then re-applies the current URL.
  /// Called by the auth notifier before any request so the right server is hit.
  Future<void> ensureApplied() async {
    load();
    await _loading;
    if (!_disposed) apply();
  }
}
