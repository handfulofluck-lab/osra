import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

Future<void> configureDateFormatting() async {
  DateFormat.useNativeDigitsByDefaultFor('ar', false);
  await initializeDateFormatting();
}

String formatDayHeader(DateTime date, String locale) {
  return DateFormat.yMMMMEEEEd(locale).format(date);
}
