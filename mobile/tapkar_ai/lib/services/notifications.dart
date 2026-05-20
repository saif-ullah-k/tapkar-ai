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

  /// Provider-side: fires when a new booking arrives. The provider's
  /// jobs tab notices the new id during polling and calls this so the
  /// provider hears a ping even when the app isn't in foreground.
  Future<void> newJobReceived({
    required String category,
    String timeIso = '',
  }) async {
    final readable = category.replaceAll('_', ' ');
    await _show(
      'New booking request',
      timeIso.isNotEmpty
          ? 'New $readable job — ${timeIso.substring(0, 16).replaceAll('T', ' ')}'
          : 'You have a new $readable booking request',
    );
  }

  /// Either side: fires when the other party messages you about a booking.
  /// Polling code in Jobs/Bookings tabs calls this when it spots a
  /// message id that wasn't seen before.
  Future<void> chatMessage({
    required String fromLabel,
    required String preview,
  }) async {
    await _show(
      'New message from $fromLabel',
      preview.length > 80 ? preview.substring(0, 80) + '…' : preview,
    );
  }
}
