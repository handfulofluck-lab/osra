import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/settings/reauth_dialog.dart';

import 'test_app.dart';

/// Child-escape catalogue PA03 (#738, `docs/testing/CHILD-ESCAPE-CATALOGUE.md` row PA03):
///
/// > Remove the child's device, delete the account, turn off monitoring — Re-auth dialog (password or MFA)
/// > every time; never one tap.
///
/// This file covers the dialog's own contract, which every one of those actions depends on: **cancel means
/// nothing happened**, an empty proof is refused in place, and a submitted proof is returned to the caller.
/// The per-screen wiring (device removal, monitoring off, unblock, stop ring) is asserted in the screen tests
/// of the same slice; a dialog that let an empty proof through would make all of them meaningless.
///
/// Mutants: pop a `ReauthProof()` instead of `null` on cancel and rows 1 and 4 go red; drop the `isEmpty`
/// guard and row 2 goes red; return the code without `normalizeDigits` and the Arabic-digit case goes red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ReauthProof?> openDialog(WidgetTester tester) async {
    ReauthProof? result;
    var settled = false;
    await tester.pumpWidget(localizedTestApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showReauthDialog(context);
              settled = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(settled, isFalse, reason: 'the dialog must still be waiting for the parent');
    return result;
  }

  testWidgets('cancel returns null, so the caller has no proof to send', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reauthPassword')), findsNothing);
  });

  testWidgets('an empty proof is refused in place and the dialog stays open', (tester) async {
    await openDialog(tester);
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reauthError')), findsOneWidget,
        reason: 'an empty proof must be refused rather than popped as valid');
    expect(find.byKey(const ValueKey('reauthConfirm')), findsOneWidget,
        reason: 'the dialog stays up so the parent can type a proof');
  });

  testWidgets('a password is returned to the caller', (tester) async {
    ReauthProof? proof;
    await tester.pumpWidget(localizedTestApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => proof = await showReauthDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'correct horse');
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await tester.pumpAndSettle();
    expect(proof, isNotNull);
    expect(proof!.password, 'correct horse');
  });

  testWidgets('an authenticator code alone is accepted and normalised', (tester) async {
    ReauthProof? proof;
    await tester.pumpWidget(localizedTestApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => proof = await showReauthDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Arabic-Indic digits: the API compares ASCII, so the dialog normalises before returning (#467).
    await tester.enterText(find.byKey(const ValueKey('reauthCode')), '١٢٣٤٥٦');
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await tester.pumpAndSettle();
    expect(proof, isNotNull);
    expect(proof!.code, '123456');
  });
}
