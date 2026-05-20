import 'package:intl/intl.dart';

// Bookings, reminders, and time-slot ISOs are anchored to Asia/Karachi
// (UTC+5). Phones in any other timezone would otherwise shift the day
// backward via `toLocal()` (e.g. a 2026-05-21T08:00:00+05:00 booking
// renders as "Wed 11 PM" on a US-Eastern phone instead of "Thu 8 AM").
// Always format these timestamps in PKT.
DateTime _toPKT(String iso) =>
    DateTime.parse(iso).toUtc().add(const Duration(hours: 5));

String formatBookingWhen(String iso) {
  try {
    return DateFormat('EEE, d MMM · h:mm a').format(_toPKT(iso));
  } catch (_) {
    return iso;
  }
}

String formatFollowUpWhen(String iso) {
  try {
    return DateFormat('EEE h:mm a').format(_toPKT(iso));
  } catch (_) {
    return iso;
  }
}
