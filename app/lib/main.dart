import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/core/foreground/driver_foreground_service.dart';
import 'src/core/notifications/notification_service.dart';
import 'src/core/notifications/push_service.dart';
import 'src/core/prefs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Nothing in this app's UI is designed for landscape — a live-tracking
  // map, swipe sheets, and the fullscreen nav screen all assume portrait.
  // Locked before the first frame so it never even flashes landscape on a
  // device that starts rotated.
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  final prefs = await SharedPreferences.getInstance();
  // Fast/local only — `NotificationService.consumePendingLaunchLink()`
  // (drained once, synchronously, by `notificationNavProvider` on the very
  // first frame) genuinely needs this done first; see its own comment.
  await NotificationService.instance.init();
  DriverForegroundService.init();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const SaarathiApp(),
    ),
  );

  // Deliberately NOT awaited before `runApp()`: `Firebase.initializeApp()` +
  // the FCM permission prompt + `getToken()` are real network/IPC calls to
  // Google Play Services that can take anywhere from tens of ms to well
  // over a second. Awaiting this here used to block the first frame behind
  // it — and since this whole `main()` re-runs identically whenever Android
  // reclaims a backgrounded process and later recreates it (not just on a
  // true cold launch), that showed up as a blank flash of `NormalTheme`'s
  // plain background on ordinary app resume, not just first install.
  // `PushService.register` already races safely against this (see its own
  // `_ready`-retry).
  unawaited(PushService.instance.init());
}
