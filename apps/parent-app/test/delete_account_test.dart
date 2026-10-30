import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/settings/delete_account_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #442 PR 2: the in-app half of account deletion.
///
/// Two deletions share this screen, and picking the wrong one is the failure that matters: an owner's
/// `DELETE /v1/me` refuses with `owner_must_delete_family`, and a co-parent's `DELETE /v1/family`
/// refuses with `owner_role_required` — neither deletes, but a parent who is shown the wrong action has
/// been told the wrong thing about their family. So the scope comes from the role, and these rows pin
/// which request each role makes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Mq fakeApi({Map<String, dynamic>? familyMe, FakeRoute? onDelete}) {
    final me = familyMe ?? familyMeTwoChildren();
    return Mq(me: me, onDelete: onDelete);
  }

  Future<void> pumpScreen(WidgetTester tester, Mq api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api.client)],
      child: localizedTestApp(const DeleteAccountScreen()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Types the email into the confirmation field and forks the re-auth dialog to `password`.
  Future<void> confirmWith(WidgetTester tester, String email) async {
    await tester.enterText(find.byKey(const ValueKey('deleteAccountConfirm')), email);
    await tester.pump();
    // The screen is a long scroll, so on the 800x600 surface the button can start below the fold.
    await tester.ensureVisible(find.byKey(const ValueKey('deleteAccountSubmit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('deleteAccountSubmit')));
    await tester.pumpAndSettle();
    // Asserted here so a missed tap fails at the tap rather than three steps later (#469 review).
    expect(find.text('Confirm it is you'), findsOneWidget);
    // The dialog's own keys, as `mfa_screens_test.dart` drives it: `find.byType(TextField).first` is
    // the screen's email field, still mounted behind the dialog.
    await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'good-password');
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await flush(tester);
  }

  testWidgets('R1 the owner is shown the family deletion and DELETE /v1/family is sent', (tester) async {
    final api = fakeApi();
    await pumpScreen(tester, api);

    expect(find.text('Delete account'), findsWidgets);
    expect(find.textContaining('deletes your whole family'), findsOneWidget);
    expect(find.textContaining('The family and its children stay.'), findsNothing);

    await confirmWith(tester, 'qa@familyshield.dev');

    expect(api.client.calls('DELETE', '/v1/family'), hasLength(1));
    expect(api.client.calls('DELETE', '/v1/me'), isEmpty);
    expect(api.client.calls('DELETE', '/v1/family').single.body['password'], 'good-password');
  });

  testWidgets('R2 a co-parent is shown the self deletion and DELETE /v1/me is sent', (tester) async {
    final me = familyMeTwoChildren();
    (me['parent'] as Map<String, dynamic>)['role'] = 'co-parent';
    final api = fakeApi(familyMe: me);
    await pumpScreen(tester, api);

    expect(find.textContaining('deletes your account and signs you out'), findsOneWidget);
    expect(find.textContaining('deletes your whole family'), findsNothing);

    await confirmWith(tester, 'qa@familyshield.dev');

    expect(api.client.calls('DELETE', '/v1/me'), hasLength(1));
    expect(api.client.calls('DELETE', '/v1/family'), isEmpty);
    // Mutant: decide the scope from anything but the role and this pair of rows swaps.
  });

  testWidgets('R3 the email comparison trims and ignores case', (tester) async {
    final api = fakeApi();
    await pumpScreen(tester, api);

    final button = () => tester.widget<FilledButton>(find.byKey(const ValueKey('deleteAccountSubmit')));
    expect(button().onPressed, isNull, reason: 'empty confirmation');

    // Mutant: compare the raw strings and `QA@…` with a trailing space leaves the button dead.
    await tester.enterText(find.byKey(const ValueKey('deleteAccountConfirm')), '  QA@FamilyShield.dev  ');
    await tester.pump();
    expect(button().onPressed, isNotNull);

    await tester.enterText(find.byKey(const ValueKey('deleteAccountConfirm')), 'someone@else.dev');
    await tester.pump();
    expect(button().onPressed, isNull);
  });

  testWidgets('R4 a refusal renders its sentence and deletes nothing', (tester) async {
    final api = fakeApi(
      onDelete: (_) => const FakeHttpError(409, {'error': 'consent_records_held'}),
    );
    await pumpScreen(tester, api);
    await confirmWith(tester, 'qa@familyshield.dev');

    expect(find.byKey(const ValueKey('deleteAccountError')), findsOneWidget);
    expect(find.textContaining('consent records for a child in another family'), findsOneWidget);
    expect(find.textContaining('consent_records_held'), findsNothing);
    // Mutant: swallow the refusal and the parent is left on a screen that looks like it worked.
    expect(find.byKey(const ValueKey('deleteAccountSubmit')), findsOneWidget);
  });

  testWidgets('R5 while the role is unknown there is a spinner and neither copy', (tester) async {
    // The screen's own contract, tested at the widget: a null overview is "not loaded yet", and both
    // copies offer a deletion, so neither may appear until the role is known. Driving this through the
    // provider is not possible with the fake — its routes resolve in a microtask, so the overview is
    // never actually in flight — and a row that can only pass by luck is worth less than this one.
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(fakeApi().client)],
      child: localizedTestApp(const Scaffold(body: OverviewNotLoaded(overview: null, child: SizedBox()))),
    ));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('deletes your whole family'), findsNothing);
    expect(find.textContaining('deletes your account and signs you out'), findsNothing);
  });

  testWidgets('R6 a failed overview shows the error and a Retry, not a spinner forever', (tester) async {
    final api = Mq(
      me: familyMeTwoChildren(),
      failFamilyMe: true,
    );
    await pumpScreen(tester, api);

    expect(find.text('Could not load your family. Check your connection and try again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('deleteAccountRetry')), findsOneWidget);
    expect(find.textContaining('deletes your whole family'), findsNothing);
    // Mutant: keep the spinner and the parent waits on a screen that will never answer.
  });
}

/// A fake API plus the keys this screen needs, so each row states only what it varies.
class Mq {
  Mq({required Map<String, dynamic> me, FakeRoute? onDelete, bool failFamilyMe = false})
      : client = FakeApiClient({
          ...standardRoutes(familyMe: me),
          if (failFamilyMe) 'GET /v1/family/me': (_) => const FakeHttpError(500, {'error': 'boom'}),
          'DELETE /v1/family': onDelete ?? (_) => {'deleted': 'family'},
          'DELETE /v1/me': onDelete ?? (_) => {'deleted': 'parent'},
        });

  final FakeApiClient client;
}
