import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/push/background_push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final arabicIndicDigits = RegExp(r'[\u0660-\u0669\u06F0-\u06F9]');

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('Arabic dates and times use Western digits through app configuration', () async {
    await configureDateFormatting();
    final at = DateTime(2026, 11, 14, 16, 8, 43);

    final formatted = DateFormat.yMMMd('ar').add_Hms().format(at);

    expect(formatted, isNot(contains(arabicIndicDigits)));
    expect(formatted, contains('14'));
    expect(formatted, contains('16:08:43'));
  });

  test('the day header follows the Arabic locale order with Western digits', () async {
    await configureDateFormatting();

    expect(formatDayHeader(DateTime(2026, 11, 14), 'ar'), 'السبت، 14 نوفمبر 2026');
    expect(formatDayHeader(DateTime(2026, 11, 14), 'en'), 'Saturday, November 14, 2026');
  });

  test('the background entry point configures Western Arabic digits', () async {
    await firebaseMessagingBackgroundHandler(const RemoteMessage());

    final formatted = DateFormat.yMMMd('ar').format(DateTime(2026, 11, 14));
    expect(formatted, isNot(contains(arabicIndicDigits)));
    expect(formatted, contains('14'));
  });
}
