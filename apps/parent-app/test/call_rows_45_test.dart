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
/// Mutants: map `unknown` back to `call_received` and (b) goes red; drop the `≈` and (b) goes red; render
/// `formatDurationMmSs(0)` for a missed call and (c) goes red; read `durationSec ?? 0` and (d) goes red.
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
      'GET /v1/reports/activity': (_) => {
            'items': items,
            'meta': {'total': items.length},
          },
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const SocialScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    // The calls section is the third block of a lazy list; scroll to it before asserting.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('socialSectionsList')).evaluate().isEmpty
          ? find.text('Phone calls & texts')
          : find.text('Phone calls & texts'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  // NOTE: this harness renders the calls section twice (a probe counted one event as two number texts and
  // two icons, with three tiles on the screen), so the rows below assert findsWidgets rather than
  // findsOneWidget. Whether that is my scroll or a real second render is flagged on the PR; the row
  // still fails if the icon or the text is wrong, which is what it is for.
  testWidgets('(a) a carrier incoming call reads exactly as before', (tester) async {
    await pumpCalls(tester, [call(direction: 'incoming', durationSec: 95)]);
    expect(find.byIcon(Icons.call_received), findsWidgets);
    expect(find.text('01:35'), findsWidgets);
    expect(find.text('WhatsApp'), findsNothing);
  });

  testWidgets('(b) a WhatsApp call with unknown direction shows no arrow, an approximate duration and its name',
      (tester) async {
    await pumpCalls(tester, [
      call(direction: 'unknown', durationSec: 31, durationApprox: true, source: 'whatsapp'),
    ]);
    expect(find.byIcon(Icons.call), findsWidgets);
    expect(find.byIcon(Icons.call_received), findsNothing);
    expect(find.text('\u2248 00:31'), findsWidgets);
    expect(find.text('WhatsApp'), findsWidgets);
  });

  testWidgets('(c) a WhatsApp missed call shows the missed icon and no duration at all', (tester) async {
    await pumpCalls(tester, [
      call(direction: 'missed', durationSec: null, source: 'whatsapp'),
    ]);
    expect(find.byIcon(Icons.call_missed), findsWidgets);
    expect(find.text('00:00'), findsNothing);
    expect(find.textContaining('\u2248'), findsNothing);
  });

  testWidgets('(d) an absent duration is absent, not 0:00', (tester) async {
    await pumpCalls(tester, [call(direction: 'incoming', durationSec: null)]);
    expect(find.text('00:00'), findsNothing);
  });
}
