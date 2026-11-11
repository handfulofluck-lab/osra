import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/phone_setup_section.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-0034 decision 3 — the parent's "Phone setup" block.
///
/// Three rules this suite exists to keep: an **absent** feature key renders nothing (the phone did not say,
/// which is not the same as "not available"); `not_supported` is the *server's* word and reads as "not in this
/// version" rather than as a fault of the phone; and a device that never reported says so instead of showing an
/// empty row of failures.
String _readShared(String relative) {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = File('${dir.path}/$relative');
    if (candidate.existsSync()) return candidate.readAsStringSync();
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('could not find $relative');
    dir = parent;
  }
}

void main() {
  Device device({
    Map<String, String>? features,
    List<String> missing = const [],
    bool stale = false,
    int? others,
    List<String> kinds = const [],
    bool withSetup = true,
  }) =>
      Device.fromJson({
        'id': 'dev-1',
        'childId': 'child-1',
        'platform': 'android',
        'model': 'Pixel 7a',
        'osVersion': '15',
        'status': 'online',
        'batteryPct': 80,
        if (withSetup)
          'setup': {
            'reportedAt': '2026-11-10T09:15:00.000Z',
            'stale': stale,
            'features': features ?? <String, String>{},
            'missing': missing,
            'profiles': others == null ? null : {'others': others, 'kinds': kinds},
          },
      });

  Future<void> pump(WidgetTester tester, Device d, {Locale locale = const Locale('en')}) async {
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: PhoneSetupSection(device: d))),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a phone that never reported says so, and shows no failures', (tester) async {
    await pump(tester, device(withSetup: false));
    expect(find.text('This phone has not reported what it can do yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('phoneSetupSection')), findsNothing);
    expect(find.text('Ready'), findsNothing);
  });

  testWidgets('the four states read as the product says, and an absent key renders nothing', (tester) async {
    await pump(
      tester,
      device(features: {
        'lock_screen': 'ready',
        'web_filter': 'degraded',
        'pause_internet': 'unavailable',
        'notification_scan': 'not_supported',
      }),
    );
    expect(find.text('Lock screen · Ready'), findsOneWidget);
    expect(find.text('Web filter · Limited'), findsOneWidget);
    expect(find.text('Pause internet · Not available'), findsOneWidget);
    // The server's word, not a fault of the phone: the Play artefact cannot do it at all.
    expect(find.text('Notification scan · Not in this version'), findsOneWidget);
    // `call_sms_log` was never reported: no chip, and certainly not "Not available".
    expect(find.textContaining('Calls and texts'), findsNothing);
  });

  testWidgets('the fix list names the grants a parent can act on', (tester) async {
    await pump(
      tester,
      device(missing: ['accessibility', 'location']),
    );
    expect(find.text('What to fix on the phone'), findsOneWidget);
    expect(find.text('• Accessibility service'), findsOneWidget);
    expect(find.text('• Location (allow all the time)'), findsOneWidget);
    expect(find.text('Every permission this phone needs is in place.'), findsNothing);
  });

  testWidgets('nothing missing is said plainly, not left blank', (tester) async {
    await pump(tester, device(features: {'lock_screen': 'ready'}));
    expect(find.text('Every permission this phone needs is in place.'), findsOneWidget);
    expect(find.text('What to fix on the phone'), findsNothing);
  });

  testWidgets('a second space is named, and zero spaces says nothing at all', (tester) async {
    await pump(tester, device(others: 1, kinds: ['clone']));
    expect(find.textContaining('cloned apps'), findsOneWidget);

    await pump(tester, device(others: 0));
    expect(find.textContaining('another space'), findsNothing);
    expect(find.textContaining('cloned apps'), findsNothing);
  });

  testWidgets('a stale report says so, with the age', (tester) async {
    await pump(tester, device(stale: true, features: {'lock_screen': 'ready'}));
    expect(find.textContaining('may not have caught up'), findsOneWidget);
  });

  testWidgets('the Arabic copy renders, so the block is not English-only on an Arabic phone', (tester) async {
    await pump(
      tester,
      device(features: {'lock_screen': 'ready'}, missing: ['accessibility']),
      locale: const Locale('ar'),
    );
    expect(find.text('إعداد الهاتف'), findsOneWidget);
    expect(find.text('شاشة القفل · جاهز'), findsOneWidget);
    expect(find.text('• خدمة إمكانية الوصول'), findsOneWidget);
  });

  testWidgets('all thirteen grant keys get a human label, and the list matches the shared vocabulary', (tester) async {
    // #552 review, point 1: three keys (full_screen_intent, family_controls, background_refresh) reached the
    // screen as raw wire names. Looping the whole vocabulary is what makes a *future* grant fail here instead.
    final source = _readShared('packages/shared-types/src/capabilities.ts');
    final block = RegExp(r'export const GRANT_KEYS = \[([^\]]*)\]', dotAll: true).firstMatch(source)!.group(1)!;
    final shared = RegExp("\"([a-z_]+)\"").allMatches(block).map((m) => m.group(1)!).toList();
    expect(shared.length, 13, reason: 'the vocabulary grew or shrank; update the widget and this row together');
    expect(PhoneSetupSection.grantKeys, shared,
        reason: 'the widget must carry the same order and the same keys as the server');

    await pump(tester, device(missing: PhoneSetupSection.grantKeys));
    for (final key in PhoneSetupSection.grantKeys) {
      expect(find.text('• $key'), findsNothing, reason: '$key has no human label');
    }
    // And each one is present as *something* meant for a parent, not silently dropped.
    expect(find.textContaining('• '), findsNWidgets(13));
  });

  testWidgets('another space with no named kind still says there is one', (tester) async {
    // #552 review, point 2: `others: 1` with empty or unknown kinds showed nothing at all.
    await pump(tester, device(others: 1, kinds: const []));
    expect(find.textContaining('another space'), findsOneWidget);

    await pump(tester, device(others: 2, kinds: const ['a_kind_from_the_future']));
    expect(find.textContaining('another space'), findsOneWidget);
  });

}
