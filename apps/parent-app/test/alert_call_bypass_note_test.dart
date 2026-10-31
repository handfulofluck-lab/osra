import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #444, Claude's ruling of 2026-10-31: the sentence belongs in the parent app's `block_bypass`
/// alert dialog **when `metadata.layout` is `call`** — the screen the parent opens from that exact
/// alert — not in the insight sheet or an FAQ they may never open.
///
/// Mutants: drop the `layout == 'call'` condition and the second row goes red (the split-screen alert
/// gains a sentence about a call); drop the whole block and the first row goes red.
void main() {
  Map<String, dynamic> tamperAlert({required String layout}) => {
        ...alertJson('a9', 'warning', 'tamper', 'A blocked app stayed on screen', DateTime.utc(2026, 10, 31, 2)),
        'metadata': <String, dynamic>{'type': 'block_bypass', 'app': 'com.example.meet', 'layout': layout},
      };

  Future<void> openAlert(WidgetTester tester, Map<String, dynamic> alert) async {
    final api = FakeApiClient(standardRoutes(alerts: [alert]));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const AlertsScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('An app got around the block'));
    await tester.pumpAndSettle();
  }

  const note = "The call app was blocked, but its call kept going under the block screen. "
      "OSRA can't end another app's call, so the screen stays blocked until the call ends.";

  testWidgets('a call bypass alert says the call kept going', (tester) async {
    await openAlert(tester, tamperAlert(layout: 'call'));
    expect(find.byKey(const ValueKey('alert-call-bypass-note')), findsOneWidget);
    expect(find.text(note), findsOneWidget);
  });

  testWidgets('a split-screen bypass alert says nothing about a call', (tester) async {
    await openAlert(tester, tamperAlert(layout: 'split_screen'));
    expect(find.byKey(const ValueKey('alert-call-bypass-note')), findsNothing);
    expect(find.textContaining('its call kept going'), findsNothing);
  });
}
