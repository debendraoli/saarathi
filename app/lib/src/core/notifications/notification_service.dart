import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Foreground/local notifications. Production push (FCM/APNs) layers on top of
/// this: the FCM handler simply calls [show]. Kept dependency-light so the app
/// builds without Firebase config; wire FCM once google-services files exist.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings);
    _ready = true;
  }

  Future<void> show(String title, String? body) async {
    if (!_ready) await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'saarathi_default',
        'Saarathi',
        channelDescription: 'Trip, delivery and safety alerts',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }
}
