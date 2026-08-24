import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_controller.dart';
import '../../features/notifications/data/notifications_repository.dart';
import '../router/app_router.dart';
import '../router/deep_links.dart';
import '../storage/token_store.dart';
import 'notification_service.dart';
import 'push_service.dart';

/// Routes a tapped notification to its screen — a foreground tap (local
/// notification, [NotificationService.onTap]) or a background/terminated tap
/// (FCM's own tray notification, [PushService.onTap]) both carry the same
/// `saarathi://…` link, so both feed the same [routeForDeepLink] used for
/// external deep links. Also bumps the inbox the moment a push lands while
/// the app is open, so the bell badge doesn't wait on the next poll.
/// Keep-alive so the subscription lives for the app's lifetime; watch it once
/// from the app root, same as [deepLinkHandlerProvider].
final notificationNavProvider = Provider<void>((ref) {
  final router = ref.watch(goRouterProvider);

  void handle(String link) {
    final target = routeForDeepLink(Uri.parse(link));
    if (target != null) router.go(target);
  }

  // A scheduled notification (e.g. the merchant-review reminder) can launch
  // the app from fully killed — that link was captured during `init()`,
  // before this provider existed to listen for it. Drain it once here.
  final launchLink = NotificationService.instance.consumePendingLaunchLink();
  if (launchLink != null) handle(launchLink);

  final subs = [
    NotificationService.instance.onTap.listen(handle),
    PushService.instance.onTap.listen(handle),
    PushService.instance.onForegroundMessage
        .listen((_) => ref.invalidate(inboxProvider)),
    // Single-device-per-account: this account just logged in elsewhere.
    // Ignore it if the signal is about the very device that just logged
    // in (comparing against this device's own persistent id); otherwise
    // this device was the one revoked — sign out immediately instead of
    // waiting for the next failed refresh.
    PushService.instance.onForceLogout.listen((newDeviceId) async {
      final myId = await ref.read(tokenStoreProvider).deviceId;
      if (newDeviceId != myId) {
        await ref.read(authControllerProvider.notifier).signOut();
      }
    }),
  ];
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
  });
});
