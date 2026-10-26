import 'dart:ui' show Locale;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/permission_errors.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';

/// ADR-0014 amendment, decision 7: a read the invite does not cover says **that**, and names the fix.
/// These rows pin which refusals are recognised, because telling a guardian to ask the owner for access
/// when the real problem is a stale token would send them to the wrong person.

DioException refusal(int status, Object? body) => DioException(
      requestOptions: RequestOptions(path: '/v1/alerts'),
      response: Response(requestOptions: RequestOptions(path: '/v1/alerts'), statusCode: status, data: body),
    );

void main() {
  group('ReadPermissionRequired.from', () {
    test('recognises the server refusal and keeps which permission was needed', () {
      final refused = ReadPermissionRequired.from(refusal(403, {'error': 'permission_required', 'permission': 'alerts'}));

      expect(refused, isNotNull);
      expect(refused!.permission, 'alerts');
    });

    test('ignores a 403 that is not a permission refusal', () {
      // `cross_child_forbidden` and `session_revoked` also arrive as 403, and neither is the owner's
      // to fix.
      expect(ReadPermissionRequired.from(refusal(403, {'error': 'cross_child_forbidden'})), isNull);
      expect(ReadPermissionRequired.from(refusal(403, {'error': 'session_revoked'})), isNull);
    });

    test('ignores a permission_required body on a non-403', () {
      expect(ReadPermissionRequired.from(refusal(500, {'error': 'permission_required', 'permission': 'alerts'})), isNull);
    });

    test('ignores a 403 whose body is not the server shape', () {
      expect(ReadPermissionRequired.from(refusal(403, 'forbidden')), isNull);
      expect(ReadPermissionRequired.from(refusal(403, {'error': 'permission_required'})), isNull);
      expect(ReadPermissionRequired.from(refusal(403, {'error': 'permission_required', 'permission': ''})), isNull);
    });

    test('ignores a failure with no response at all', () {
      final timedOut = DioException(requestOptions: RequestOptions(path: '/v1/alerts'), type: DioExceptionType.connectionTimeout);

      expect(ReadPermissionRequired.from(timedOut), isNull);
    });
  });

  group('permissionRequiredMessage', () {
    test('is the localized sentence naming the owner, in both languages', () {
      final en = lookupAppLocalizations(const Locale('en'));
      final ar = lookupAppLocalizations(const Locale('ar'));

      expect(permissionRequiredMessage(en), 'Your family owner can give you access to this.');
      expect(permissionRequiredMessage(ar), 'يمكن لمالك العائلة منحك حق الوصول إلى هذا.');
      // The permission name is deliberately not interpolated: `alerts` in the middle of an Arabic
      // sentence reads as a bug to the guardian reading it.
      expect(permissionRequiredMessage(ar), isNot(contains('alerts')));
    });
  });
}
