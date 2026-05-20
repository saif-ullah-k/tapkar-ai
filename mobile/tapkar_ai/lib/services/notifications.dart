import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local push notifications — surfaces booking events in the system tray
/// even when the user isn't on the chat screen. Single channel, low
/// configuration, no FCM/server-side setup needed.
///
/// Lifecycle: call `Notifications.instance.init()` once from main(), then
/// `Notifications.instance.bookingConfirmed(...)` whenever a booking flips
/// to confirmed (or other status transitions worth notifying on).
class Notifications {
  Notifications._();
  static final Notifications instance = Notifications._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1000;

  static const _channelId = 'tapkar_booking_updates';
  static const _channelName = 'Booking updates';
  static const _channelDescription =
      'Notifications for booking confirmations and reminders';

  Future<void> init() async {
    if (_ready) return;
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: androidInit);
      await _plugin.initialize(settings: settings);

      // Android 13+ requires runtime POST_NOTIFICATIONS permission.
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();

      _ready = true;
    } catch (e) {
      // Notifications are an enhancement, not core — silently degrade.
      debugPrint('[notifications] init failed: $e');
    }
  }

  Future<void> _show(String title, String body) async {
    if (!_ready) await init();
    if (!_ready) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        ticker: 'TapKar AI',
      );
      const details = NotificationDetails(android: androidDetails);
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('[notifications] show failed: $e');
    }
  }

  Future<void> bookingConfirmed({
    required String providerName,
    String? category,
  }) async {
    final cat = (category == null || category.isEmpty) ? 'service' : category;
    await _show(
      'Booking confirmed',
      '$providerName has accepted your $cat booking.',
    );
  }

  Future<void> bookingRequested({
    required String providerName,
  }) async {
    await _show(
      'Booking sent',
      'Waiting for $providerName to confirm…',
    );
  }

  Future<void> bookingCompleted({
    required String providerName,
  }) async {
    await _show(
      'Booking completed',
      '$providerName has completed your booking.',
    );
  }
}
