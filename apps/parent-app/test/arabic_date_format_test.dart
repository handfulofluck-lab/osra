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

  /**
   * #762 / #760: the alert list and the social timeline grouped by `DateFormat('yyyy-MM-dd')`, which
   * consults the ambient locale **and** the native-digit setting — in the state #760 was seen in that key
   * was `٢٠٢٦-١١-١٤`, `DateTime.tryParse` rejects it, and the header fell back to the raw key. `dayKey`
   * ignores both settings, so the label always parses back and renders in the locale's order.
   */
  test('the grouping key is independent of the ambient locale and the digit setting', () async {
    await configureDateFormatting();
    Intl.defaultLocale = 'ar';
    addTearDown(() async {
      Intl.defaultLocale = null;
      await configureDateFormatting(); // puts Western digits back for ar
    });
    final day = DateTime(2026, 11, 14);

    // The state the bug was reported in: native digits on, so the old key could not be parsed back.
    DateFormat.useNativeDigitsByDefaultFor('ar', true);
    final oldKey = DateFormat('yyyy-MM-dd').format(day);
    expect(oldKey, contains(arabicIndicDigits));
    expect(DateTime.tryParse(oldKey), isNull);

    // The key that ships does not consult either setting.
    final key = dayKey(day);
    expect(key, '2026-11-14');
    expect(DateTime.tryParse(key), day);

    DateFormat.useNativeDigitsByDefaultFor('ar', false);
    expect(formatDayHeader(DateTime.tryParse(key)!, 'ar'), 'السبت، 14 نوفمبر 2026');
  });

  test('the background entry point configures Western Arabic digits', () async {
    await firebaseMessagingBackgroundHandler(const RemoteMessage());

    final formatted = DateFormat.yMMMd('ar').format(DateTime(2026, 11, 14));
    expect(formatted, isNot(contains(arabicIndicDigits)));
    expect(formatted, contains('14'));
  });
}
