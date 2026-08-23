import 'dart:async';

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

  /// Emits the notification's `link` (if any) when the user taps a locally
  /// shown notification — i.e. one we displayed ourselves while the app was
  /// in the foreground. Background/terminated taps go through FCM's own
  /// onMessageOpenedApp / getInitialMessage instead (see PushService).
  final _tapController = StreamController<String>.broadcast();
  Stream<String> get onTap => _tapController.stream;

  Future<void> init() async {
    if (_ready) return;
    // The status-bar icon must be an alpha-only silhouette, not the
    // full-color launcher icon — Android renders a color icon as a blank
    // white square in the notification tray on API 21+.
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_notify'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final link = response.payload;
        if (link != null && link.isNotEmpty) _tapController.add(link);
      },
    );
    _ready = true;
  }

  Future<void> show(String title, String? body, {String? link}) async {
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
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: details,
      payload: link,
    );
  }
}
