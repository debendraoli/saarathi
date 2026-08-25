import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../features/places/data/maps_url_parser.dart';
import '../../features/places/data/places_repository.dart';
import 'app_router.dart';
import '../scaffold_messenger.dart';

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

  // Bumped before every resolve attempt below; a call whose generation has
  // been superseded by a newer one by the time its network round-trip
  // finishes discards its own result instead of navigating — otherwise two
  // links arriving close together race, and whichever's resolveGoogleMapsUrl
  // happens to finish *last* would win the navigation regardless of which
  // one actually arrived last.
  var generation = 0;
  Uri? lastHandledUri;

  Future<bool> tryOpenAsMapsPin(String text) async {
    if (!containsGoogleMapsUrl(text)) return false;
    final myGeneration = ++generation;
    final messenger = rootScaffoldMessengerKey.currentState;
    final l = messenger == null ? null : AppL10n.of(messenger.context);
    if (l != null) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(
        content: Text(l.resolvingSharedLink),
        duration: const Duration(seconds: 12),
      ));
    }
    final resolved = await resolveGoogleMapsUrl(text);
    if (myGeneration != generation) {
      // Superseded — a newer link/share owns the snackbar now; don't stomp
      // on it or navigate for this stale one. Still report "handled" so the
      // caller doesn't fall through to routeForDeepLink for what was a real
      // (if stale) Maps link.
      return true;
    }
    if (resolved == null) {
      if (l != null) {
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(SnackBar(content: Text(l.sharedLinkFailed)));
      }
      // Definitely a Maps link (containsGoogleMapsUrl was true) that just
      // failed to resolve — not something routeForDeepLink would ever
      // match either way, so still "handled".
      return true;
    }
    messenger?.hideCurrentSnackBar();
    // Navigate the moment there's a point — not once there's a human label
    // for it too. Waiting on the reverse-geocode here meant a cold start
    // via a shared link sat on whatever the router's initial route is
    // (Home) until both network calls finished; this way the request sheet
    // opens immediately, in its own "resolving…" shimmer state (see
    // `WhereToScreen`'s handling of this exact coordinate-string format),
    // and the label(s) fill in over it a moment later.
    final hit = PlaceHit(
      label: coordLabel(resolved.destination),
      point: resolved.destination,
    );
    // A "Directions" link's origin (only ever a raw coordinate — see
    // `resolveGoogleMapsUrl`'s doc comment) rides along as a query param
    // rather than through `extra`, since `extra` here is `PlaceHit?` and
    // several other callers of this same route already depend on that
    // shape (`app_router.dart`'s `Routes.whereTo` GoRoute reads the param
    // back into `WhereToScreen.initialPickup`).
    final origin = resolved.origin;
    final path = origin == null
        ? Routes.whereTo
        : '${Routes.whereTo}?originLat=${origin.latitude}&originLng=${origin.longitude}';
    router.go(path, extra: hit);
    return true;
  }

  Future<void> handle(Uri uri) async {
    // `getInitialLink()` and the first `uriLinkStream` emission can both
    // fire for the very same cold-start link on some platforms/app_links
    // versions — skip an exact repeat of the link just handled rather than
    // resolving (and navigating) twice.
    if (uri == lastHandledUri) return;
    lastHandledUri = uri;
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
