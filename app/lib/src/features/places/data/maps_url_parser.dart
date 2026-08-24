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

/// `.../@lat,lng,zoom...`, `?q=lat,lng`, or the `!3dlat!4dlng` pin-marker
/// form Google Maps embeds in some share links — checked in that order: the
/// pin marker is the actual place coordinate when present, more precise
/// than `@lat,lng`'s viewport-center point (which can drift slightly for a
/// place-search result vs. a dropped pin).
LatLng? _extractLatLng(String url) {
  final pin = RegExp(r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)').firstMatch(url);
  if (pin != null) {
    return LatLng(double.parse(pin.group(1)!), double.parse(pin.group(2)!));
  }
  final at = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(url);
  if (at != null) {
    return LatLng(double.parse(at.group(1)!), double.parse(at.group(2)!));
  }
  final q = RegExp(r'[?&]q=(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(url);
  if (q != null) {
    return LatLng(double.parse(q.group(1)!), double.parse(q.group(2)!));
  }
  return null;
}

/// Android's Share Sheet can hand this a bare link or, from some apps, a
/// short caption plus the link ("Check out this place: https://…") — pull
/// out the first URL-shaped substring rather than requiring the whole
/// string to parse as one.
final _urlPattern = RegExp(r'https?://\S+');

/// Resolves a pasted or shared Google Maps link to a point. Long-form URLs
/// (`.../@lat,lng,...` or `?q=lat,lng`) are parsed directly with no network
/// call; short links (`maps.app.goo.gl/...`) carry no coordinates in the URL
/// itself, so this follows the redirect first — a bare, unauthenticated Dio
/// instance is used deliberately, not [ApiClient]'s, since this hits an
/// external host, not our own API base. Returns null for anything that
/// isn't a resolvable Google Maps link, same graceful-degrade convention as
/// the rest of the search flow.
Future<LatLng?> resolveGoogleMapsUrl(String text) async {
  final trimmed = _urlPattern.firstMatch(text.trim())?.group(0) ?? text.trim();
  if (!looksLikeGoogleMapsUrl(trimmed)) return null;
  final direct = _extractLatLng(trimmed);
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
    return _extractLatLng(response.realUri.toString());
  } catch (_) {
    return null;
  }
}
