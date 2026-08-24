import 'package:latlong2/latlong.dart';

import '../features/places/data/places_repository.dart';

/// Reverse-geocode results keyed by rounded lat/lng (~11m precision), shared
/// process-wide. Screens that reverse-geocode the same handful of points on
/// a poll loop (driver offer cards, the in-trip sheet) hit this instead of
/// hammering `/v1/geo/reverse` on every tick.
final _cache = <String, String?>{};

String _key(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';

/// A human label for [point] — the cached value if we have one, else fetches
/// and caches it (best-effort: a failed lookup caches as null rather than
/// retrying every call). Takes the repository directly (not a `ref`) so it
/// works equally from a `WidgetRef` call site and from inside a provider,
/// which only exposes the narrower `Ref`.
Future<String?> reverseGeocodeCached(
    PlacesRepository repo, LatLng point) async {
  final key = _key(point);
  if (_cache.containsKey(key)) return _cache[key];
  String? label;
  try {
    final hit = await repo.reverse(point);
    label = hit?.label.isNotEmpty == true ? hit!.label : hit?.address;
  } catch (_) {
    label = null;
  }
  _cache[key] = label;
  return label;
}
