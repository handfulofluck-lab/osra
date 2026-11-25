import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';
import 'frame_capture.dart';
import 'test_app.dart';

enum _FrameState {
  request,
  saving,
  allowed,
  kept,
  error,
  coParent,
  legacy,
  readOnly,
  ordinary,
}

const _stateNames = {
  _FrameState.request: 'request',
  _FrameState.saving: 'saving',
  _FrameState.allowed: 'allowed',
  _FrameState.kept: 'kept-blocked',
  _FrameState.error: 'error',
  _FrameState.coParent: 'co-parent',
  _FrameState.legacy: 'legacy-resolved',
  _FrameState.readOnly: 'read-only',
  _FrameState.ordinary: 'ordinary',
};

Alert _frameAlert(_FrameState state) => Alert(
      id: 'request-1',
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'warning',
      category: 'app_blocked',
      body: 'Child requested access to com.example.security',
      metadata: {
        'packageId': 'com.example.security',
        'appName': 'Metadata Security',
        if (state != _FrameState.ordinary) 'requestType': 'access',
        if (state == _FrameState.legacy || state == _FrameState.coParent)
          'requestType': null,
        if (state == _FrameState.coParent) ...{
          'resolution': 'allowed',
          'resolvedByName': 'Mariam',
          'resolvedAt': '2026-11-25T08:05:00.000Z',
        },
      },
      title: state == _FrameState.legacy || state == _FrameState.coParent
          ? 'Access requested'
          : 'App blocked',
      createdAt: DateTime.utc(2026, 11, 25, 8),
      acknowledged:
          state == _FrameState.legacy || state == _FrameState.coParent,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFrameFonts);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpFrame(
    WidgetTester tester,
    _FrameState state, {
    required Locale locale,
    required bool dark,
    required bool narrow,
  }) async {
    tester.view.physicalSize =
        narrow ? const Size(320, 1000) : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = narrow ? 2 : 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    final alert = _frameAlert(state);
    final family = familyMeTwoChildren();
    if (state == _FrameState.readOnly) {
      family['parent'] = {
        ...(family['parent'] as Map<String, dynamic>),
        'role': 'guardian',
        'permissions': ['alerts'],
      };
      family['parents'] = [
        family['parent'],
        {
          'id': 'owner-1',
          'familyId': 'fam-1',
          'email': 'owner@example.com',
          'displayName': 'Mariam',
          'role': 'owner',
          'permissions': <String>[],
        },
      ];
    }
    final routes = standardRoutes(
      familyMe: family,
      alerts: [
        {
          'id': alert.id,
          'childId': alert.childId,
          'deviceId': alert.deviceId,
          'severity': alert.severity,
          'category': alert.category,
          'title': alert.title,
          'body': alert.body,
          'metadata': alert.metadata,
          'createdAt': alert.createdAt!.toIso8601String(),
          'acknowledged': alert.acknowledged,
        },
      ],
    );
    routes['POST /v1/alerts/request-1/ack'] = (_) => {'ok': true};
    if (state == _FrameState.error) {
      routes['PATCH /v1/rules/child-1'] = (_) => const FakeHttpError(500);
    }
    final saveCompleter = Completer<Object?>();
    if (state == _FrameState.saving) {
      routes['PATCH /v1/rules/child-1'] =
          (_) => FakeDeferred(saveCompleter.future);
    }
    final api = FakeApiClient(routes);
    final light = withFrameFonts(AppTheme.light);
    final darkTheme = withFrameFonts(AppTheme.dark);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          RepaintBoundary(
            key: const ValueKey('frameRoot'),
            child: AlertDetailScreen(
              alertId: alert.id,
              initialAlert: alert,
              nowProvider: () => DateTime(2026, 11, 25, 12, 5),
            ),
          ),
          locale: locale,
          textDirection: locale.languageCode == 'ar'
              ? TextDirection.rtl
              : TextDirection.ltr,
          theme: light,
          darkTheme: darkTheme,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        ),
      ),
    );
    await flush(tester);

    if (state == _FrameState.request) {
      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('access-allow')));
      final actualFamily = button.style?.textStyle?.resolve(const <WidgetState>{})?.fontFamily;
      final expectedFamily = Theme.of(tester.element(find.byKey(const ValueKey('access-allow'))))
          .textTheme
          .labelLarge
          ?.fontFamily;
      expect(actualFamily, expectedFamily);
    }

    if (state == _FrameState.saving ||
        state == _FrameState.allowed ||
        state == _FrameState.error) {
      await tester
          .tap(find.text(locale.languageCode == 'ar' ? 'السماح' : 'Allow'));
      if (state == _FrameState.saving) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      } else {
        await flush(tester);
      }
    } else if (state == _FrameState.kept) {
      await tester
          .tap(find.text(locale.languageCode == 'ar' ? 'رفض' : 'Keep blocked'));
      await flush(tester);
    }

    expect(
        find.byKey(const ValueKey('alertDetailGeneralScroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final sizeLabel = narrow ? '320-200' : '390';
    await maybeCaptureFrame(
      tester,
      'access-${_stateNames[state]}-${locale.languageCode}-${dark ? 'dark' : 'light'}-$sizeLabel.png',
    );
    if (state == _FrameState.saving) {
      saveCompleter.complete({'ok': true});
      await flush(tester);
    }
  }

  for (final state in _FrameState.values) {
    for (final locale in [const Locale('en'), const Locale('ar')]) {
      for (final dark in [false, true]) {
        for (final narrow in [true, false]) {
          testWidgets(
            '${_stateNames[state]} ${locale.languageCode} ${dark ? 'dark' : 'light'} ${narrow ? '320 200%' : '390'}',
            (tester) => pumpFrame(tester, state,
                locale: locale, dark: dark, narrow: narrow),
          );
        }
      }
    }
  }
}
