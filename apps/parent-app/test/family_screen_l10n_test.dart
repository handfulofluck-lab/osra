import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/features/family/family_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #419 / #420: the family screen in Arabic. A refused read names the owner (decision 7), the dialog's
/// buttons keep their roles, and roles and permissions are words, not the API's wire values.

DioException refusal(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 403,
        data: {'error': 'permission_required', 'permission': 'alerts'},
      ),
    );

FakeApiClient familyApi() => FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family/invites': (_) => {
            'items': [
              {'id': 'inv-1', 'email': 'nana@example.com', 'role': 'guardian', 'status': 'pending', 'permissions': ['location', 'alerts']},
            ],
          },
      'POST /v1/family/invites': (req) => {
            'invite': {'email': 'nana@example.com'},
            'acceptToken': 'tok-123',
          },
    });

void main() {
  final ar = lookupAppLocalizations(const Locale('ar'));

  Future<void> pumpFamily(WidgetTester tester, FakeApiClient api, {List<Override> overrides = const []}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api), ...overrides],
      child: localizedTestApp(const FamilyScreen(), locale: const Locale('ar'), textDirection: TextDirection.rtl),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a refused family read names the owner, not "failed to load"', (tester) async {
    await pumpFamily(tester, familyApi(), overrides: [
      familyProvider.overrideWith((ref) => throw refusal('/v1/family/me')),
    ]);
    expect(find.text(ar.readPermissionRequired), findsOneWidget);
    expect(find.textContaining('تعذّر تحميل العائلة'), findsNothing);
  });

  testWidgets('a refused invites read names the owner, not "failed to load"', (tester) async {
    await pumpFamily(tester, familyApi(), overrides: [
      familyInvitesProvider.overrideWith((ref) => throw refusal('/v1/family/invites')),
    ]);
    expect(find.text(ar.readPermissionRequired), findsOneWidget);
    expect(find.textContaining('تعذّر تحميل الدعوات'), findsNothing);
  });

  testWidgets('roles and permissions read as words, not wire values', (tester) async {
    await pumpFamily(tester, familyApi());
    // The owner's chip and the pending guardian invite.
    expect(find.widgetWithText(Chip, ar.mfaResetRoleOwner), findsOneWidget);
    // The permissions are joined with the Arabic comma, not a Latin one (#426).
    expect(find.text('${ar.mfaResetRoleGuardian} · ${ar.familyPermLocation}، ${ar.familyPermAlerts}'), findsOneWidget);
    expect(find.textContaining('${ar.familyPermLocation}, '), findsNothing);
    expect(find.textContaining('guardian'), findsNothing);

    await tester.tap(find.text(ar.familyInviteMember));
    await tester.pumpAndSettle();
    for (final label in [ar.familyPermRules, ar.familyPermLocation, ar.familyPermAlerts, ar.familyPermSocial]) {
      expect(find.widgetWithText(CheckboxListTile, label), findsOneWidget, reason: label);
    }
  });

  testWidgets('the invite dialog keeps each label on its own button, before and after sending', (tester) async {
    await pumpFamily(tester, familyApi());
    await tester.tap(find.text(ar.familyInviteMember));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, ar.cancel), findsOneWidget);
    expect(find.widgetWithText(FilledButton, ar.familySendInvite), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nana@example.com');
    await tester.tap(find.widgetWithText(FilledButton, ar.familySendInvite));
    await tester.pumpAndSettle();
    expect(find.text(ar.familyInviteSentTo('nana@example.com')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, ar.familyDone), findsOneWidget);
    expect(find.widgetWithText(TextButton, ar.familyCopyToken), findsOneWidget);
  });
}
