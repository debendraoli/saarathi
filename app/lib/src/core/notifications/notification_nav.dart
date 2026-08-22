import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/notifications/data/notifications_repository.dart';
import '../router/app_router.dart';
import '../router/deep_links.dart';
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

  final subs = [
    NotificationService.instance.onTap.listen(handle),
    PushService.instance.onTap.listen(handle),
    PushService.instance.onForegroundMessage
        .listen((_) => ref.invalidate(inboxProvider)),
  ];
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
  });
});
