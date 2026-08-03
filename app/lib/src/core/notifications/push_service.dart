import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import 'notification_service.dart';

/// Firebase Cloud Messaging wiring. Guarded so the app still runs before a
/// Firebase project is configured (`flutterfire configure` generates the native
/// config); until then, push is simply disabled. Foreground messages render via
/// [NotificationService]. The device token is registered with the backend
/// (POST /v1/me/push-token) so the notify service can target this device.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  String? _token;
  bool _ready = false;

  Future<void> init() async {
    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      _token = await messaging.getToken();
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) {
          NotificationService.instance.show(n.title ?? 'Saarathi', n.body);
        }
      });
      messaging.onTokenRefresh.listen((t) => _token = t);
      _ready = true;
    } catch (_) {
      // Firebase not configured yet — push disabled, app runs normally.
    }
  }

  /// Register (or refresh) this device's push token for the signed-in user.
  Future<void> register(ApiClient api) async {
    if (!_ready || _token == null) return;
    try {
      await api.post(
        '/v1/me/push-token',
        body: {'token': _token, 'platform': defaultTargetPlatform.name},
      );
    } catch (_) {/* best effort */}
  }
}
