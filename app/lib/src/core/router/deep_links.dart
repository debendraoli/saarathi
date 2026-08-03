import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_router.dart';

/// Maps an incoming `saarathi://` link to an in-app route, or null if we don't
/// recognise it. Custom-scheme links arrive as `saarathi://trip/<id>`, so the
/// leading segment lands in [Uri.host] with the rest in [Uri.pathSegments].
String? routeForDeepLink(Uri uri) {
  final segments = [
    uri.host,
    ...uri.pathSegments,
  ].where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) return null;
  final id = segments[1];
  switch (segments[0]) {
    case 'trip':
    case 'ride':
      return '${Routes.trip}/$id';
    case 'order':
      return '${Routes.order}/$id';
  }
  return null;
}

/// Activates deep-link handling: forwards `saarathi://` links (cold-start and
/// while running) to the router. Keep-alive so the subscription lives for the
/// app's lifetime; watch it once from the app root.
final deepLinkHandlerProvider = Provider<void>((ref) {
  final router = ref.watch(goRouterProvider);
  final links = AppLinks();

  void handle(Uri uri) {
    final target = routeForDeepLink(uri);
    if (target != null) router.go(target);
  }

  // Cold start: the link that launched the app.
  links.getInitialLink().then((uri) {
    if (uri != null) handle(uri);
  });
  // Warm: links delivered while the app is already running.
  final sub = links.uriLinkStream.listen(handle);
  ref.onDispose(sub.cancel);
});
