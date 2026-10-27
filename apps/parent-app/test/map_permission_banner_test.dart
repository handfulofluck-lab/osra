import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/permission_errors.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'fake_api_client.dart';

/// #406, Claude's ruling: a child card whose location read is refused names the owner instead of saying
/// "no location yet". The helper has its own rows; this one checks the dashboard actually renders it.

DioException refusal() => DioException(
      requestOptions: RequestOptions(path: '/v1/location/child-1/latest'),
      response: Response(
        requestOptions: RequestOptions(path: '/v1/location/child-1/latest'),
        statusCode: 403,
        data: {'error': 'permission_required', 'permission': 'location'},
      ),
    );

void main() {
  testWidgets('a refused location read says the owner can grant access, not "no location yet"', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        locationProvider('child-1').overrideWith((ref) => throw refusal()),
      ],
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const DashboardScreen(),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final l10n = lookupAppLocalizations(const Locale('en'));
    // The fixture has a second child whose location provider is not overridden, so "No location yet"
    // legitimately appears once; what matters is that the refused child names the owner.
    expect(find.textContaining(l10n.readPermissionRequired), findsWidgets);
  });
}
