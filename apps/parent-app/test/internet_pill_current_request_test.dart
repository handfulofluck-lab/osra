import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  final child = Child.fromJson({'id': 'child-1', 'displayName': 'Test child', 'birthYear': 2015});

  for (final row in [
    (
      'a pause returned before all devices acknowledge',
      'pause',
      ['delivered', 'pending'],
      'Pausing internet…',
      false,
    ),
    (
      'a pause confirmed by every target',
      'pause',
      ['acked', 'acked'],
      'Internet paused',
      false,
    ),
    (
      'a resume with one failed device',
      'resume',
      ['acked', 'failed'],
      'Resumed on some devices',
      true,
    ),
    (
      'a resume confirmed by every target',
      'resume',
      ['acked', 'acked'],
      'Internet resumed',
      false,
    ),
    (
      'a pause with no remaining device confirmation path',
      'pause',
      ['unknown', 'unknown'],
      'Pause not confirmed',
      true,
    ),
    (
      'a resume recorded with no paired devices',
      'resume',
      <String>[],
      'Resume not confirmed',
      true,
    ),
  ]) {
    final (description, action, statuses, ui, showsDelivery) = row;
    testWidgets(description, (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final api = FakeApiClient({
        'GET /v1/controls/children/child-1/status': (_) => {
          'paused': action == 'pause',
          'internetRequest': {
            'action': action,
            'devices': [for (final status in statuses) {'status': status}],
          },
        },
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          Scaffold(body: InternetPill(child: child)),
          theme: AppTheme.light,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(ui), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Command delivery'), showsDelivery ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
