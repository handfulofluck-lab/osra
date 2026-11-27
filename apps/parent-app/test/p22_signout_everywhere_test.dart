import 'package:familyshield_parent/features/settings/settings_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// P-22 / osra-security#92 (Claude, 11:36 UAE; Codex 7211995144): **Sign out of all devices** revokes every
/// session. On success the phone is cleared; on failure it is **not** — the parent still holds a live session
/// and must be able to retry, so the failure has to surface instead of silently signing them out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pump(WidgetTester tester, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
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
    await tester.pumpAndSettle();
  }

  testWidgets('a confirmed sign out everywhere revokes the account sessions once', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/auth/logout-all': (_) => {'ok': true},
    });
    await pump(tester, api);
    await confirmSignOutEverywhere(tester);

    expect(api.calls('POST', '/v1/auth/logout-all'), hasLength(1));
    expect(find.byType(SnackBar), findsNothing, reason: 'a success is not announced as a failure');
  });

  testWidgets('a failed revocation keeps the parent signed in and says so', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/auth/logout-all': (_) => const FakeHttpError(500),
    });
    await pump(tester, api);
    await confirmSignOutEverywhere(tester);

    expect(api.calls('POST', '/v1/auth/logout-all'), hasLength(1));
    expect(find.byType(SnackBar), findsOneWidget,
        reason: 'the parent must learn the sign out did not happen, and can retry');
    expect(find.byType(SettingsScreen), findsOneWidget,
        reason: 'the phone is not cleared on a failed revocation');
  });
}
