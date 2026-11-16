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
   * #762 / #760: the lists grouped by `DateFormat('yyyy-MM-dd')`, which formats with whatever digits the
   * ambient locale prints. A key in Arabic digits cannot be parsed back — `DateTime.tryParse` rejects it —
   * so `_dayLabel` fell through to the raw key and the header showed an ISO date. `dayKey` builds the key
   * from the date fields, so it never depends on the ambient locale or a digit setting, and the header
   * always gets a real date back to format in the locale's order.
   */
  test('the grouping key is locale-independent and always parses back', () async {
    await configureDateFormatting();
    Intl.defaultLocale = 'ar';
    addTearDown(() => Intl.defaultLocale = null);
    final day = DateTime(2026, 11, 14);

    // Why a locale-formatted key is the wrong tool: these digits are what a locale may print, and they
    // cannot be parsed back — the state the raw ISO header came from.
    expect(DateTime.tryParse('٢٠٢٦-١١-١٤'), isNull);

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
