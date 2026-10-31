import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The wall clock a sentence about "now" is computed from (#456).
///
/// A provider rather than a `DateTime.now()` call inside the widget: the routine sentence depends on
/// the time of day and the weekday, and a row that cannot set the clock cannot test a weekday morning
/// (the whole point of the issue). `ProviderScope(overrides: [clockProvider.overrideWithValue(() =>
/// DateTime(2026, 10, 30, 10, 0))])` pins it.
typedef Clock = DateTime Function();

final clockProvider = Provider<Clock>((ref) => DateTime.now);
