import 'package:familyshield_parent/features/settings/settings_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// P-22 (`#1179`, Bureau row): a plain grouped list with the current value on every row — language and
/// appearance, security, account — and **no Parent PIN row** (Fix 4). Every label is an approved key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pump(WidgetTester tester,
      {bool twoStepOn = true, Locale locale = const Locale('en')}) async {
    final family = familyMeTwoChildren();
    // A21: the family clock, so the read-only time zone row has a real offset to show.
    family['family'] = {
      ...(family['family'] as Map<String, dynamic>),
      'utcOffsetMinutes': 240,
    };
    family['parent'] = {
      ...(family['parent'] as Map<String, dynamic>),
      'mfaEnabled': twoStepOn,
    };
    final api = FakeApiClient(standardRoutes(familyMe: family));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        p22SettingsEnabledProvider.overrideWithValue(true),
      ],
      child: localizedTestApp(const SettingsScreen(), locale: locale),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the three groups and their rows are on the screen, with no Parent PIN row',
      (tester) async {
    await pump(tester);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Language and appearance'), findsOneWidget);
    expect(find.text('Security'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    for (final key in [
      'settingsRow-language',
      'settingsRow-appearance',
      'settingsRow-twoStep',
      'settingsRow-signOut',
      'settingsRow-signOutAll',
      'settingsRow-digest',
      'settingsRow-deleteAccount',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key must be on the list');
    }
    // Fix 4: the phone lock is the only app-level unlock, so no PIN row exists here.
    expect(find.textContaining('PIN'), findsNothing);
  });

  testWidgets('two-step verification shows its current value, and recovery codes only when it is on',
      (tester) async {
    await pump(tester, twoStepOn: true);
    expect(find.text('On'), findsOneWidget);
    expect(find.byKey(const ValueKey('settingsRow-recoveryCodes')), findsOneWidget);

    await pump(tester, twoStepOn: false);
    expect(find.text('Off'), findsOneWidget);
    expect(find.byKey(const ValueKey('settingsRow-recoveryCodes')), findsNothing,
        reason: 'there are no recovery codes to open while two-step verification is off');
  });




  testWidgets('the time zone row is read-only and shows the family offset, never an IANA id', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('settingsRow-timeZone')), findsOneWidget);
    // fixture family: utcOffsetMinutes 240 -> UTC+4, in Western digits
    // ltrIsolate wraps the digits in isolate marks, so the match is a contains, not an exact text.
    expect(find.textContaining('UTC+4'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing, reason: 'never the raw Asia/Dubai id');
    final tile = tester.widget<ListTile>(find.byKey(const ValueKey('settingsRow-timeZone')));
    expect(tile.enabled, isFalse, reason: 'read-only until #1211: no chevron and no ripple');
  });

  testWidgets('the security card is on top while two-step verification is off, and gone when it is on',
      (tester) async {
    await pump(tester, twoStepOn: false);
    expect(find.byKey(const ValueKey('settingsSecurityCard')), findsOneWidget);
    expect(find.text('Finish securing your account'), findsOneWidget);
    expect(find.byKey(const ValueKey('settingsSecurityCardButton')), findsOneWidget);

    await pump(tester, twoStepOn: true);
    expect(find.byKey(const ValueKey('settingsSecurityCard')), findsNothing,
        reason: 'the card shows only while something is unfinished');
  });

  testWidgets('sign out of all devices asks first, and cancel touches nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('settingsRow-signOutAll')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsSignOutAllDialog')), findsOneWidget);
    expect(find.text('Sign out everywhere'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settingsSignOutAllCancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsSignOutAllDialog')), findsNothing,
        reason: 'cancel is the default and closes the dialog without revoking anything');
  });

  testWidgets('the list reads in Arabic', (tester) async {
    await pump(tester, locale: const Locale('ar'));
    expect(find.text('الإعدادات'), findsOneWidget);
    expect(find.text('الأمان'), findsOneWidget);
    expect(find.text('تسجيل الخروج من كل الأجهزة'), findsOneWidget);
  });
}
