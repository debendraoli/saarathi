import 'dart:async';

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
///
/// Background/terminated pushes need no app code at all — they carry a
/// `notification` payload, so the OS shows them directly and FCM hands the
/// tap back via [onMessageOpenedApp] / `getInitialMessage`.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  String? _token;
  bool _ready = false;
  ApiClient? _lastApi;

  /// Emits the tapped notification's `link` for a background/terminated
  /// push. Foreground taps come from [NotificationService.onTap] instead —
  /// merge both in whatever wires up navigation.
  final _tapController = StreamController<String>.broadcast();
  Stream<String> get onTap => _tapController.stream;

  /// Fires on every push received while the app is in the foreground — the
  /// inbox badge should reflect it immediately, not wait for the next poll
  /// or a manual pull-to-refresh.
  final _receivedController = StreamController<void>.broadcast();
  Stream<void> get onForegroundMessage => _receivedController.stream;

  Future<void> init() async {
    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      _token = await messaging.getToken();
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) {
          NotificationService.instance.show(
            n.title ?? 'Saarathi',
            n.body,
            link: m.data['link'] as String?,
          );
          _receivedController.add(null);
        }
      });
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        final link = m.data['link'] as String?;
        if (link != null && link.isNotEmpty) _tapController.add(link);
      });
      final initial = await messaging.getInitialMessage();
      final initialLink = initial?.data['link'] as String?;
      if (initialLink != null && initialLink.isNotEmpty) {
        _tapController.add(initialLink);
      }
      // A token can rotate at any time while the app stays signed in (FCM
      // reissues them e.g. after a restore or a security refresh) — without
      // re-registering, the backend keeps sending to a dead token and this
      // device silently stops getting push.
      messaging.onTokenRefresh.listen((t) {
        _token = t;
        final api = _lastApi;
        if (api != null) register(api);
      });
      _ready = true;
    } catch (_) {
      // Firebase not configured yet — push disabled, app runs normally.
    }
  }

  /// Register (or refresh) this device's push token for the signed-in user.
  Future<void> register(ApiClient api) async {
    _lastApi = api;
    if (!_ready || _token == null) return;
    try {
      await api.post(
        '/v1/me/push-token',
        body: {'token': _token, 'platform': defaultTargetPlatform.name},
      );
    } catch (_) {/* best effort */}
  }

  /// Drop this device's token on sign-out so a shared/reused device stops
  /// receiving the signed-out user's pushes until someone logs in again.
  Future<void> unregister(ApiClient api) async {
    if (!_ready || _token == null) return;
    try {
      await api.delete('/v1/me/push-token', body: {'token': _token});
    } catch (_) {/* best effort */}
    _lastApi = null;
  }
}
