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
  Future<void> onDestroy(DateTime timestamp) async {}
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

  /// Ask the OS to exclude the app from battery optimisation so it isn't killed
  /// while the driver is online (Android Doze). No-op on iOS.
  static Future<void> requestBatteryExclusion() async {
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  static Future<bool> get isBatteryOptimizationIgnored =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;
}
