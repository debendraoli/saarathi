import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../features/places/data/maps_url_parser.dart';
import '../../features/places/data/places_repository.dart';
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
    case 'wallet':
      return Routes.wallet;
    case 'merchant':
      return Routes.merchantDashboard;
  }
  return null;
}

/// Activates deep-link handling: forwards `saarathi://` links (cold-start and
/// while running) to the router, and (Android only — see the SEND
/// intent-filter in AndroidManifest.xml) picks up a Google Maps location
/// shared into Saarathi via the OS Share Sheet. A direct tap on a Maps link
/// can't be routed into the app at all: that requires Digital Asset Links
/// domain verification on google.com itself, which isn't ours to provide —
/// the Share Sheet is the one path in that doesn't need it, since any app
/// declaring a matching intent-filter is offered regardless of domain
/// ownership. Keep-alive so the subscription lives for the app's lifetime;
/// watch it once from the app root.
final deepLinkHandlerProvider = Provider<void>((ref) {
  final router = ref.watch(goRouterProvider);
  final links = AppLinks();

  Future<bool> tryOpenAsMapsPin(String text) async {
    final mapsPoint = await resolveGoogleMapsUrl(text);
    if (mapsPoint == null) return false;
    // Navigate the moment there's a point — not once there's a human label
    // for it too. Waiting on the reverse-geocode here meant a cold start
    // via a shared link sat on whatever the router's initial route is
    // (Home) until both network calls finished; this way the request sheet
    // opens immediately, in its own "resolving…" shimmer state (see
    // `WhereToScreen`'s handling of this exact coordinate-string format),
    // and the label fills in over it a moment later.
    final hit = PlaceHit(
      label:
          '${mapsPoint.latitude.toStringAsFixed(5)}, ${mapsPoint.longitude.toStringAsFixed(5)}',
      point: mapsPoint,
    );
    router.go(Routes.whereTo, extra: hit);
    return true;
  }

  Future<void> handle(Uri uri) async {
    if (await tryOpenAsMapsPin(uri.toString())) return;
    final target = routeForDeepLink(uri);
    if (target != null) router.go(target);
  }

  Future<void> handleShared(List<SharedMediaFile> files) async {
    for (final f in files) {
      if (await tryOpenAsMapsPin(f.path)) return;
    }
  }

  // Cold start: the link that launched the app.
  links.getInitialLink().then((uri) {
    if (uri != null) handle(uri);
  });
  // Warm: links delivered while the app is already running.
  final sub = links.uriLinkStream.listen(handle);
  ref.onDispose(sub.cancel);

  // Cold start via the Share Sheet.
  ReceiveSharingIntent.instance.getInitialMedia().then((files) {
    if (files.isNotEmpty) {
      handleShared(files);
      ReceiveSharingIntent.instance.reset();
    }
  });
  // Warm: shared while the app is already running.
  final shareSub =
      ReceiveSharingIntent.instance.getMediaStream().listen(handleShared);
  ref.onDispose(shareSub.cancel);
});
