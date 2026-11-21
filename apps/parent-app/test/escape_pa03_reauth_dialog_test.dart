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
/// Mutants (each must turn exactly the named rows red):
/// - cancel pops a `ReauthProof` instead of `null` and row 1 goes red;
/// - drop the `isEmpty` guard and row 2 goes red;
/// - drop `normalizeDigits` and row 4 goes red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The harness exists because an earlier version of this file read the dialog's result before the button
  // that produces it was tapped, so a Cancel that leaked a proof could not be observed (Antigravity's F1,
  // `PR #978`). Holding the result and a "the await returned" flag makes that failure possible to see.
  Future<_Harness> open(WidgetTester tester) async {
    final harness = _Harness();
    await tester.pumpWidget(localizedTestApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              harness.proof = await showReauthDialog(context);
              harness.settled = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(harness.settled, isFalse, reason: 'the dialog must still be waiting for the parent');
    return harness;
  }

  testWidgets('cancel returns null, so the caller has no proof to send', (tester) async {
    final harness = await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.settled, isTrue, reason: 'Cancel must complete the await rather than leave it hanging');
    expect(harness.proof, isNull, reason: 'Cancel must yield no proof; a sentinel here would be sent as one');
    expect(find.byKey(const ValueKey('reauthPassword')), findsNothing);
  });

  testWidgets('an empty proof is refused in place and the dialog stays open', (tester) async {
    final harness = await open(tester);
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reauthError')), findsOneWidget,
        reason: 'an empty proof must be refused rather than popped as valid');
    expect(find.byKey(const ValueKey('reauthConfirm')), findsOneWidget,
        reason: 'the dialog stays up so the parent can type a proof');
    expect(harness.settled, isFalse);
  });

  testWidgets('a password is returned to the caller', (tester) async {
    final harness = await open(tester);
    await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'correct horse');
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await tester.pumpAndSettle();
    expect(harness.proof, isNotNull);
    expect(harness.proof!.password, 'correct horse');
  });

  testWidgets('an authenticator code alone is accepted and normalised', (tester) async {
    final harness = await open(tester);
    // Arabic-Indic digits: the API compares ASCII, so the dialog normalises before returning (#467).
    await tester.enterText(find.byKey(const ValueKey('reauthCode')), '١٢٣٤٥٦');
    await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
    await tester.pumpAndSettle();
    expect(harness.proof, isNotNull);
    expect(harness.proof!.code, '123456');
  });
}

class _Harness {
  /// Deliberately pre-seeded with a value a leaking Cancel would leave in place: `null` here would make
  /// row 1 pass whether or not the dialog popped a proof.
  ReauthProof? proof = const ReauthProof(password: 'sentinel');
  bool settled = false;
}
