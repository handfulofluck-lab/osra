import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/time_request_actions.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'frame_capture.dart';
import 'test_app.dart';

const _now = '2026-11-26T16:00:00Z';
const _request = <String, dynamic>{
  'id': 'frame-request',
  'childId': 'child-1',
  'deviceId': 'dev-1',
  'category': 'app_blocked',
  'severity': 'info',
  'createdAt': '2026-11-26T15:00:00Z',
  'metadata': {'requestType': 'time', 'reason': 'daily_limit', 'minutes': '15'},
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final narrow in [false, true]) {
    for (final dark in [false, true]) {
      for (final detail in [false, true]) {
        for (final resolved in [false, true]) {
          final size = narrow ? '320-200' : '390';
          final theme = dark ? 'dark' : 'light';
          final view = detail ? 'detail' : 'card';
          final state = resolved ? 'resolved' : 'pending';
          testWidgets('$view $state $theme $size', (tester) async {
            tester.view.physicalSize =
                narrow ? const Size(320, 1000) : const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = narrow ? 2 : 1;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.platformDispatcher.clearTextScaleFactorTestValue();
            });

            await tester.runAsync(loadFrameFonts);
            final json = {
              ..._request,
              if (resolved) ...{
                'acknowledged': true,
                'timeRequestResolution': {
                  'action': 'grant',
                  'minutes': 30,
                  'actorName': 'Sarah',
                  'resolvedAt': '2026-11-26T15:05:00Z',
                },
              },
            };
            final alert = Alert.fromJson(json);
            final api = FakeApiClient(standardRoutes(alerts: [json]));
            await tester.pumpWidget(ProviderScope(
              overrides: [apiClientProvider.overrideWithValue(api)],
              child: localizedTestApp(
                RepaintBoundary(
                  key: const ValueKey('frameRoot'),
                  child: detail
                      ? AlertDetailScreen(
                          alertId: alert.id,
                          initialAlert: alert,
                          nowProvider: () => DateTime.parse(_now),
                        )
                      : Scaffold(
                          body: SingleChildScrollView(
                              child: AlertTile(alert: alert))),
                ),
                theme: withFrameFonts(AppTheme.light),
                darkTheme: withFrameFonts(AppTheme.dark),
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              ),
            ));
            for (var frame = 0; frame < 8; frame++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            final title = find.textContaining('asked for');
            expect(title, findsOneWidget);
            // Ellipsis on the card title truncates it at 320 px and 200% text.
            expect(
                tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
                isFalse);
            for (final action in ['grant-15', 'grant-30', 'decline']) {
              final button = find.byKey(ValueKey('time-request-$action'));
              if (timeRequestActionsEnabled && !resolved) {
                expect(button, findsOneWidget);
                final hitTarget = tester.getSize(button);
                expect(hitTarget.width, greaterThanOrEqualTo(48));
                expect(hitTarget.height, greaterThanOrEqualTo(48));
              } else {
                expect(button, findsNothing);
              }
            }
            final receipt = find.byKey(const ValueKey('time-request-receipt'));
            expect(
                receipt,
                timeRequestActionsEnabled && resolved
                    ? findsOneWidget
                    : findsNothing);
            expect(tester.takeException(), isNull);
            await maybeCaptureFrame(
                tester, 'p20-$view-$state-en-$theme-$size.png');
          });
        }
      }
    }
  }
}
