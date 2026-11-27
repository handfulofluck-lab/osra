import 'package:familyshield_parent/features/settings/settings_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/push/push_registration.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// A push source with a token already minted, so a re-registration is a plain POST instead of an OS prompt.
class _GrantedPushSource implements PushTokenSource {
  const _GrantedPushSource(this._value);

  final String _value;

  @override
  Future<PushPermission> requestPermission() async => PushPermission.granted;

  @override
  Future<String?> token() async => _value;
}

/// P-22 / osra-security#92 (Claude, 11:36 UAE; Codex 7211995144): **Sign out of all devices** revokes every
/// session. On success the phone is cleared; on failure it is **not** — the parent still holds a live session
/// and must be able to retry, so the failure has to surface instead of silently signing them out. The push row
/// is retired before the revocation (it authenticates with the session being revoked) and put back when the
/// revocation fails, or a parent who could not sign out has also silently stopped receiving alerts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  setUp(() {
    // Signed in: "sign out everywhere" is a row on a session that exists, and the stored tokens are what the
    // success clears and the failure must leave alone.
    FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-1', 'refresh': 'refresh-1'});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, FakeRoute> routes(FakeRoute logoutAll) => {
        ...standardRoutes(),
        'POST /v1/me/push-token': (_) => {'id': 'push-1', 'platform': 'android'},
        'DELETE /v1/me/push-token': (_) => {'removed': 1},
        'POST /v1/auth/logout-all': logoutAll,
      };

  Future<void> pump(WidgetTester tester, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        pushTokenSourceProvider.overrideWithValue(const _GrantedPushSource('push-token-1')),
        p22SettingsEnabledProvider.overrideWithValue(true),
      ],
      child: localizedTestApp(const SettingsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  // The row is below the fold at 800x600, exactly as the shipped tests drive their buttons: call the handler.
  Future<void> confirmSignOutEverywhere(WidgetTester tester) async {
    tester.widget<ListTile>(find.byKey(const ValueKey('settingsRow-signOutAll'))).onTap!();
    await tester.pumpAndSettle();
    tester.widget<TextButton>(find.byKey(const ValueKey('settingsSignOutAllConfirm'))).onPressed!();
    // The dialog's future completes when its exit animation ends, and the request after it resolves a few
    // microtask turns later; pump in steps until the row is up rather than guessing a fixed frame count.
    for (var i = 0; i < 40 && find.byType(SnackBar).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a confirmed sign out everywhere revokes the account sessions once', (tester) async {
    final api = FakeApiClient(routes((_) => {'ok': true}));
    await pump(tester, api);
    await confirmSignOutEverywhere(tester);

    expect(api.calls('POST', '/v1/auth/logout-all'), hasLength(1));
    expect(find.byType(SnackBar), findsNothing, reason: 'a success is not announced as a failure');
    expect(await storage.read(key: 'jwt'), isNull, reason: 'the phone is signed out');
    expect(await storage.read(key: 'refresh'), isNull);
  });

  testWidgets('a failed revocation keeps the parent signed in and says so', (tester) async {
    final api = FakeApiClient(routes((_) => const FakeHttpError(500)));
    await pump(tester, api);
    await confirmSignOutEverywhere(tester);

    expect(api.calls('POST', '/v1/auth/logout-all'), hasLength(1));
    expect(find.byType(SnackBar), findsOneWidget,
        reason: 'the parent must learn the sign out did not happen, and can retry');
    expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('settingsRow-signOutAll'))).onTap,
        isNotNull,
        reason: 'the row is usable again, so the retry the snackbar invites is actually possible');
    expect(await storage.read(key: 'jwt'), 'jwt-1',
        reason: 'a failed revocation leaves the session live; the phone is not cleared');
    expect(await storage.read(key: 'refresh'), 'refresh-1');
    // osra-security#92: the token retired before the revocation is registered again, or the phone that could
    // not sign out has also stopped receiving the family's alerts.
    expect(api.calls('POST', '/v1/me/push-token'), hasLength(1),
        reason: 'the push row is put back after a failed revoke');
  });
}
