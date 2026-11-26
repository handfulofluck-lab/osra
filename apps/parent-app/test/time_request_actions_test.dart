import 'dart:async';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/alerts/app_alert_presentation.dart';
import 'package:familyshield_parent/features/alerts/time_request_actions.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

const _decisionPath = '/v1/alerts/qa-request/time-decision';
const _alertJson = <String, dynamic>{
  'id': 'qa-request',
  'childId': 'child-1',
  'deviceId': 'dev-1',
  'category': 'app_blocked',
  'createdAt': '2026-11-26T15:00:00Z',
  'metadata': {'requestType': 'time', 'minutes': '15', 'reason': 'daily_limit'},
};
const _grant = {
  'action': 'grant',
  'minutes': 30,
  'actorName': 'Sarah',
  'resolvedAt': '2026-11-26T15:02:00Z',
};

Finder _button(String action) => find.byKey(ValueKey('time-request-$action'));

Future<FakeApiClient> _pump(
  WidgetTester tester,
  FakeRoute decision, {
  Alert? alert,
  Map<String, dynamic>? family,
  bool tile = false,
}) async {
  final api = FakeApiClient({
    ...standardRoutes(familyMe: family, alerts: [_alertJson]),
    'POST $_decisionPath': decision,
  });
  final request = alert ?? Alert.fromJson(_alertJson);
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api)],
    child: localizedTestApp(Scaffold(
      body:
          tile ? AlertTile(alert: request) : TimeRequestActions(alert: request),
    )),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'accepts Android decimal-string minutes and keeps access requests separate',
      () {
    final request = Alert.fromJson(_alertJson);
    expect(request.requestedScreenTimeMinutes, 15);
    expect(isAccessRequestAlert(request), isFalse);
    final access = request
        .copyWith(metadata: {'requestType': 'access', 'packageId': 'qa.app'});
    expect(access.requestedScreenTimeMinutes, isNull);
    expect(isAccessRequestAlert(access), isTrue);
    expect(
        request.copyWith(metadata: {
          'requestType': 'time',
          'minutes': 30,
          'reason': 'bedtime',
        }).requestedScreenTimeMinutes,
        isNull);
  });

  test('preserves the durable decision when a stale feed refresh arrives', () {
    final open = Alert.fromJson(_alertJson);
    final decided = Alert.fromJson({
      ..._alertJson,
      'acknowledged': true,
      'timeRequestResolution': _grant,
    });
    final merged = mergeAlertsInPlace([decided], [open]);
    expect(merged.single.acknowledged, isTrue);
    expect(merged.single.timeRequestResolution?.actorName, 'Sarah');
    expect(merged.single.timeRequestResolution?.grantedMinutes, 30);
  });

  test('keeps own decision evidence when legacy readback omits viewer identity',
      () {
    final legacy = Alert.fromJson({
      ..._alertJson,
      'acknowledged': true,
      'timeRequestResolution': _grant,
    });
    final own = legacy.copyWith(
      timeRequestResolution:
          TimeRequestResolution.fromJson(_grant, ownSubmission: true),
    );
    final confirmed = Alert.fromJson({
      ..._alertJson,
      'acknowledged': true,
      'timeRequestResolution': {..._grant, 'decidedByViewer': false},
    });
    expect(
        mergeAlertsInPlace([own], [legacy])
            .single
            .timeRequestResolution
            ?.decidedByViewer,
        isTrue);
    expect(
        mergeAlertsInPlace([own], [confirmed])
            .single
            .timeRequestResolution
            ?.decidedByViewer,
        isFalse);
  });

  testWidgets('conflict displays the caregiver and their winning grant',
      (tester) async {
    final api = await _pump(
        tester,
        (_) => const FakeHttpError(409, {
              'error': 'time_request_already_resolved',
              'resolution': _grant,
            }));
    await tester.tap(_button('grant-15'));
    await tester.pumpAndSettle();
    expect(api.calls('POST', _decisionPath).single.body,
        {'action': 'grant', 'minutes': 15});
    expect(api.requests.where((req) => req.method == 'POST'), hasLength(1));
    expect(find.textContaining('Sarah'), findsOneWidget);
    expect(find.textContaining('30'), findsOneWidget);
    expect(_button('grant-15'), findsNothing);
  });

  testWidgets('locks all actions while a grant is loading', (tester) async {
    final pending = Completer<Object?>();
    final api = await _pump(tester, (_) => FakeDeferred(pending.future));
    await tester.tap(_button('grant-30'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_button('grant-15')).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(_button('decline')).onPressed, isNull);
    pending.complete({'resolution': _grant});
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(api.calls('POST', _decisionPath).single.body,
        {'action': 'grant', 'minutes': 30});
    expect(find.text('You already gave 30 minutes today'), findsOneWidget);
  });

  testWidgets(
      'decline takes one decision request and retries after a failed write',
      (tester) async {
    var calls = 0;
    final api = await _pump(tester, (_) {
      if (++calls == 1) return const FakeHttpError(500);
      return {
        'resolution': {..._grant, 'action': 'decline', 'minutes': null}
      };
    });
    await tester.tap(_button('decline'));
    await tester.pumpAndSettle();
    expect(_button('decline'), findsOneWidget);
    await tester.tap(_button('decline'));
    await tester.pumpAndSettle();
    expect(api.calls('POST', _decisionPath).map((call) => call.body), [
      {'action': 'decline'},
      {'action': 'decline'},
    ]);
    expect(find.textContaining('declined this request'), findsOneWidget);
  });

  testWidgets('legacy acknowledged requests show the handled state',
      (tester) async {
    final api = await _pump(
        tester,
        (_) => const FakeHttpError(409, {
              'error': 'time_request_already_resolved',
              'resolution': null,
            }));
    await tester.tap(_button('grant-15'));
    await tester.pumpAndSettle();
    expect(find.text('This request was handled'), findsOneWidget);
    expect(_button('decline'), findsNothing);
    expect(api.calls('POST', _decisionPath), hasLength(1));
  });

  testWidgets('known iOS requests do not expose the Android decision controls',
      (tester) async {
    await _pump(tester, (_) => throw StateError('unexpected decision'),
        family: familyMeMixedDevices());
    expect(_button('grant-15'), findsNothing);
    expect(_button('decline'), findsNothing);
  });

  testWidgets('alert tile uses the P-20 build switch', (tester) async {
    await _pump(tester, (_) => throw StateError('unexpected decision'),
        tile: true);
    expect(_button('grant-15'),
        timeRequestActionsEnabled ? findsOneWidget : findsNothing);
  });
}
