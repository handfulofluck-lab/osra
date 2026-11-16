import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

Future<void> configureDateFormatting() async {
  DateFormat.useNativeDigitsByDefaultFor('ar', false);
  await initializeDateFormatting();
}

String formatDayHeader(DateTime date, String locale) {
  return DateFormat.yMMMMEEEEd(locale).format(date);
}

/// A locale-independent grouping key (`yyyy-MM-dd`) for [local].
///
/// `DateFormat('yyyy-MM-dd')` uses the ambient locale, and in Arabic that produces Arabic-Indic digits
/// (`٢٠٢٦-١١-١٦`). `DateTime.tryParse` rejects those, so the day header fell back to the raw key and a
/// parent read an ISO date in Arabic rather than the locale's order (#758, UI/UX Bureau on #760). The
/// key is never shown; it exists so [formatDayHeader] can be handed a real date back.
String dayKey(DateTime local) {
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
