import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

/// Recognizes a pasted Google Maps link so it can be resolved to a pin
/// instead of run through the `/v1/geo/search` autocomplete (which knows
/// nothing about arbitrary coordinates a friend shared).
bool looksLikeGoogleMapsUrl(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.hasScheme) return false;
  final host = uri.host.toLowerCase();
  return host == 'maps.app.goo.gl' ||
      host == 'goo.gl' ||
      host.endsWith('google.com') && uri.path.contains('maps');
}

/// The exact "lat, lng" text format a raw, not-yet-reverse-geocoded point
/// is shown as — shared with `where_to_screen.dart`'s `_rawCoordPattern`,
/// which watches for this precise shape to know when to show a resolving
/// shimmer instead of the label.
String coordLabel(LatLng p) =>
    '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

LatLng? _latLng(RegExpMatch? m) => m == null
    ? null
    : LatLng(double.parse(m.group(1)!), double.parse(m.group(2)!));

/// The destination point: the `!3dlat!4dlng` pin-marker form Google Maps
/// embeds in some share links, `.../@lat,lng,zoom...`, `?q=lat,lng`, or
/// (a "Directions" link's endpoint) `&destination=lat,lng` — checked in
/// that order. The pin marker is the actual place coordinate when present,
/// more precise than `@lat,lng`'s viewport-center point (which can drift
/// slightly for a place-search result vs. a dropped pin); `destination=`
/// is last since a plain place-share link never has it at all.
LatLng? _extractDestination(String url) {
  return _latLng(RegExp(r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)').firstMatch(url)) ??
      _latLng(RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(url)) ??
      _latLng(RegExp(r'[?&]q=(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(url)) ??
      _latLng(
          RegExp(r'[?&]destination=(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(url));
}

/// Only Google's documented "Directions" deep-link shape
/// (`/maps/dir/?api=1&origin=lat,lng&destination=lat,lng`, see
/// https://developers.google.com/maps/documentation/urls/get-started#directions-action)
/// reliably carries a *second*, unambiguous point — a bare `origin=` param
/// with a raw coordinate. `origin` can also be a place name/address in that
/// same scheme, but resolving free text needs a geocode call this parser
/// deliberately doesn't make (kept synchronous/regex-only past the initial
/// redirect follow), so a text origin is silently dropped rather than
/// guessed at — the caller falls back to "pickup = current location" for it,
/// same as a plain single-point share link.
LatLng? _extractOrigin(String url) =>
    _latLng(RegExp(r'[?&]origin=(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(url));

/// Android's Share Sheet can hand this a bare link or, from some apps, a
/// short caption plus the link ("Check out this place: https://…") — pull
/// out the first URL-shaped substring rather than requiring the whole
/// string to parse as one.
final _urlPattern = RegExp(r'https?://\S+');

/// A resolved Google Maps link. [destination] is always set when the link
/// resolves at all; [origin] is only set for a "Directions" link that
/// encodes both ends as coordinates — a plain place-share link (the common
/// case) has no origin of its own, and the caller should default pickup to
/// the rider's current location instead, same as booking normally does.
class ResolvedMapsLink {
  const ResolvedMapsLink({this.origin, required this.destination});
  final LatLng? origin;
  final LatLng destination;
}

ResolvedMapsLink? _extract(String url) {
  final destination = _extractDestination(url);
  if (destination == null) return null;
  return ResolvedMapsLink(
      origin: _extractOrigin(url), destination: destination);
}

/// Cheap, synchronous pre-check so a caller can tell "this is worth trying
/// to resolve" (and can show a resolving indicator) apart from "not a Maps
/// link at all" before committing to the network round-trip
/// [resolveGoogleMapsUrl] may need for a short link.
bool containsGoogleMapsUrl(String text) {
  final url = _urlPattern.firstMatch(text.trim())?.group(0) ?? text.trim();
  return looksLikeGoogleMapsUrl(url);
}

/// Resolves a pasted or shared Google Maps link. Long-form URLs
/// (`.../@lat,lng,...`, `?q=lat,lng`, or a `/dir/?...origin=...&destination=...`
/// route link) are parsed directly with no network call; short links
/// (`maps.app.goo.gl/...`) carry no coordinates in the URL itself, so this
/// follows the redirect first — a bare, unauthenticated Dio instance is used
/// deliberately, not [ApiClient]'s, since this hits an external host, not
/// our own API base. Returns null for anything that isn't a resolvable
/// Google Maps link, same graceful-degrade convention as the rest of the
/// search flow.
Future<ResolvedMapsLink?> resolveGoogleMapsUrl(String text) async {
  final trimmed = _urlPattern.firstMatch(text.trim())?.group(0) ?? text.trim();
  if (!looksLikeGoogleMapsUrl(trimmed)) return null;
  final direct = _extract(trimmed);
  if (direct != null) return direct;

  final host = Uri.tryParse(trimmed)?.host.toLowerCase();
  if (host != 'maps.app.goo.gl' && host != 'goo.gl') return null;
  try {
    final dio = Dio(BaseOptions(
      followRedirects: true,
      maxRedirects: 5,
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
    ));
    final response = await dio.get<void>(trimmed);
    return _extract(response.realUri.toString());
  } catch (_) {
    return null;
  }
}
