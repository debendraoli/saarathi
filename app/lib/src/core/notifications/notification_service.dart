import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

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

  /// The link of a *scheduled* notification that launched the app from a
  /// fully-killed state, if any. `init()` runs before `runApp` (see
  /// `main.dart`), so nothing is listening on [onTap] yet at that point —
  /// pushing straight onto the broadcast stream there would silently drop
  /// the event. Callers (`notificationNavProvider`) drain this once via
  /// [consumePendingLaunchLink] before subscribing to the live stream.
  String? _pendingLaunchLink;

  String? consumePendingLaunchLink() {
    final link = _pendingLaunchLink;
    _pendingLaunchLink = null;
    return link;
  }

  Future<void> init() async {
    if (_ready) return;
    tz_data.initializeTimeZones();
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
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _pendingLaunchLink = launchDetails!.notificationResponse?.payload;
    }
    _ready = true;
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          'saarathi_default',
          'Saarathi',
          channelDescription: 'Trip, delivery and safety alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      );

  Future<void> show(String title, String? body, {String? link}) async {
    if (!_ready) await init();
    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: _details,
      payload: link,
    );
  }

  /// Fires a one-shot notification [delay] from now — survives the app being
  /// backgrounded or killed (OS-level alarm), unlike [show]. Timing is
  /// inexact (`inexactAllowWhileIdle`) to avoid needing the Android 12+
  /// `SCHEDULE_EXACT_ALARM` permission; callers needing only an approximate
  /// delay (e.g. "remind me in ~30 minutes") don't need exact delivery.
  Future<void> scheduleDelayed({
    required int id,
    required String title,
    String? body,
    required Duration delay,
    String? link,
  }) async {
    if (!_ready) await init();
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.now(tz.UTC).add(delay),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: link,
    );
  }

  Future<void> cancel(int id) async {
    if (!_ready) await init();
    await _plugin.cancel(id: id);
  }
}
