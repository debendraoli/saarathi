import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the foreground service's background isolate.
@pragma('vm:entry-point')
void driverServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_DriverTaskHandler());
}

/// Keeps the notification fresh; the in-app driver online loop (heartbeat +
/// offer polling) keeps running because the foreground service holds the process
/// alive while the app is backgrounded.
class _DriverTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.updateService(
      notificationTitle: 'Saarathi — online',
      notificationText: 'Receiving ride & delivery requests',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Drives the sticky foreground notification that keeps a driver online in the
/// background, plus the battery-optimisation exclusion (both Android-centric).
class DriverForegroundService {
  const DriverForegroundService._();

  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'saarathi_driver_online',
        channelName: 'Driver online',
        channelDescription: 'Keeps you online to receive ride requests',
        onlyAlertOnce: true,
        // "Online since HH:MM" reads as a live status the way a persistent
        // ongoing-activity notification should, rather than a static label
        // that could have been posted at any point in the session.
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    await FlutterForegroundTask.requestNotificationPermission();
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 4210,
      notificationTitle: 'Saarathi — online',
      notificationText: 'Receiving ride & delivery requests',
      callback: driverServiceCallback,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Reflects live driver status in the persistent notification — this is
  /// the closest Android equivalent to a Dynamic Island / Live Activity:
  /// no separate widget surface exists, but the same ongoing notification
  /// already required to stay alive in the background can double as one by
  /// actually updating instead of sitting on static text the whole session.
  /// A no-op if the service isn't running (e.g. a stray call right as the
  /// driver goes offline) — nothing to update in that case.
  static Future<void> updateStatus({required int pendingOffers}) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    final hasOffers = pendingOffers > 0;
    await FlutterForegroundTask.updateService(
      notificationTitle: hasOffers
          ? 'Saarathi — $pendingOffers new request${pendingOffers > 1 ? 's' : ''}'
          : 'Saarathi — online',
      notificationText: hasOffers
          ? 'Tap to view and respond'
          : 'Receiving ride & delivery requests',
    );
  }

  /// Ask the OS to exclude the app from battery optimisation so it isn't killed
  /// while the driver is online (Android Doze). No-op on iOS.
  static Future<void> requestBatteryExclusion() async {
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  static Future<bool> get isBatteryOptimizationIgnored =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}
