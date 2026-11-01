import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Roadmap 4.5, the parent-app half: a call row must say only what the phone measured.
///
/// #523 settled the phone side — a WhatsApp call's direction is `unknown` until proven, a missed call carries
/// no duration, and a duration measured from notifications is flagged approximate. This file holds the screen
/// to the same three statements, plus the carrier rows it must keep reading exactly as before.
///
/// Two things this file learned from review (#526), both worth keeping:
///  * `activityProvider` asks `/v1/reports/activity` **twice**, once `type=call` and once `type=sms`, and merges
///    the two. A fake that ignores `type` returns the call twice and the row is drawn twice — which looked like
///    a screen bug and was the fixture. The route below filters, like the server.
///  * the "WhatsApp" label also exists in the monitoring toggles above this section, so the assertions are
///    scoped to `CallsSmsSection` rather than to the whole tree.
///
/// Mutants: map `unknown` back to `call_received` and (b) goes red; drop the `≈` and (b) goes red; remove only
/// the `missed` half of the duration guard and **(e)** goes red — that is the row the guard exists for; read an
/// absent `durationSec` as `0` and (d) goes red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  final at = DateTime.utc(2026, 10, 19, 12);

  Map<String, dynamic> call({
    String id = 'act-call',
    String number = '+15551234567',
    String direction = 'incoming',
    int? durationSec = 95,
    bool? durationApprox,
    String? source,
  }) =>
      {
        'id': id,
        'type': 'call',
        'payload': {
          'number': number,
          'direction': direction,
          if (durationSec != null) 'durationSec': durationSec,
          if (durationApprox != null) 'durationApprox': durationApprox,
          if (source != null) 'source': source,
        },
        'ts': at.toIso8601String(),
      };

  Future<void> pumpCalls(WidgetTester tester, List<Map<String, dynamic>> items) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      // The provider asks once per type and merges; a route that ignores `type` answers the call twice.
      'GET /v1/reports/activity': (req) => {
            'items': req.query['type'] == 'call' ? items : <dynamic>[],
            'meta': {'total': req.query['type'] == 'call' ? items.length : 0},
          },
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const SocialScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    // The calls section is the third block of a lazy list; scroll to it before asserting.
    await tester.scrollUntilVisible(
      find.text('Phone calls & texts'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// The row's own text, scoped to the calls section: the toggles above it also carry app names.
  Finder inCalls(String text) => find.descendant(
        of: find.byType(CallsSmsSection),
        matching: find.text(text),
      );

  testWidgets('(a) a carrier incoming call reads exactly as before', (tester) async {
    await pumpCalls(tester, [call(direction: 'incoming', durationSec: 95)]);
    expect(find.byIcon(Icons.call_received), findsOneWidget);
    expect(inCalls('01:35'), findsOneWidget);
    expect(inCalls('WhatsApp'), findsNothing);
  });

  testWidgets('(b) a WhatsApp call with unknown direction shows no arrow, an approximate duration and its name',
      (tester) async {
    await pumpCalls(tester, [
      call(direction: 'unknown', durationSec: 31, durationApprox: true, source: 'whatsapp'),
    ]);
    expect(find.byIcon(Icons.call), findsOneWidget);
    expect(find.byIcon(Icons.call_received), findsNothing);
    expect(inCalls('\u2248 00:31'), findsOneWidget);
    expect(inCalls('WhatsApp'), findsOneWidget);
  });

  testWidgets('(c) a WhatsApp missed call shows the missed icon and no duration at all', (tester) async {
    await pumpCalls(tester, [
      call(direction: 'missed', durationSec: null, source: 'whatsapp'),
    ]);
    expect(find.byIcon(Icons.call_missed), findsOneWidget);
    expect(inCalls('00:00'), findsNothing);
    expect(find.textContaining('\u2248'), findsNothing);
  });

  testWidgets('(d) an absent duration is absent, not 0:00', (tester) async {
    await pumpCalls(tester, [call(direction: 'incoming', durationSec: null)]);
    expect(find.byIcon(Icons.call_received), findsOneWidget);
    expect(inCalls('00:00'), findsNothing);
  });

  testWidgets('(e) a carrier missed call shows the missed icon and no 00:00', (tester) async {
    // The case the guard exists for, and the one the first version of this file missed: Android's call log
    // stores DURATION = 0 for a missed call and the agent uploads it as `durationSec: 0`, so the null check
    // alone is not enough — without the `missed` half this row renders "00:00" on main.
    await pumpCalls(tester, [call(direction: 'missed', durationSec: 0)]);
    expect(find.byIcon(Icons.call_missed), findsOneWidget);
    expect(inCalls('00:00'), findsNothing);
  });
}
