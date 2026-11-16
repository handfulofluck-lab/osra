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
   * #762 / #760: the alert list and the social timeline grouped by `DateFormat('yyyy-MM-dd')`, which uses
   * the ambient locale — in Arabic that is `٢٠٢٦-١١-١٤`, and `DateTime.tryParse` rejects it, so the header
   * fell back to the raw key and a parent read an ISO date instead of the locale's order. `dayKey` is
   * locale-independent, so the label parses back and renders as the Arabic long form.
   */
  test('the grouping key survives an Arabic ambient locale', () async {
    await configureDateFormatting();
    Intl.defaultLocale = 'ar';
    addTearDown(() => Intl.defaultLocale = null);
    final day = DateTime(2026, 11, 14);

    // The old key, and why it failed: Arabic digits, and tryParse returns null.
    final oldKey = DateFormat('yyyy-MM-dd').format(day);
    expect(oldKey, contains(arabicIndicDigits));
    expect(DateTime.tryParse(oldKey), isNull);

    // The key that ships.
    final key = dayKey(day);
    expect(key, '2026-11-14');
    expect(DateTime.tryParse(key), day);
    expect(formatDayHeader(DateTime.tryParse(key)!, 'ar'), 'السبت، 14 نوفمبر 2026');
  });

  test('the background entry point configures Western Arabic digits', () async {
    await firebaseMessagingBackgroundHandler(const RemoteMessage());

    final formatted = DateFormat.yMMMd('ar').format(DateTime(2026, 11, 14));
    expect(formatted, isNot(contains(arabicIndicDigits)));
    expect(formatted, contains('14'));
  });
}
