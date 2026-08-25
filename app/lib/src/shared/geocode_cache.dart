import 'package:latlong2/latlong.dart';

import '../features/places/data/places_repository.dart';

/// Reverse-geocode results keyed by rounded lat/lng (~11m precision), shared
/// process-wide. Screens that reverse-geocode the same handful of points on
/// a poll loop (driver offer cards, the in-trip sheet) hit this instead of
/// hammering `/v1/geo/reverse` on every tick.
///
/// `LinkedHashMap` for LRU: a re-touched entry is removed and reinserted so
/// it lands at the end (most-recently-used); eviction drops from the front.
/// Capped rather than unbounded — a long driver shift polling many distinct
/// points shouldn't grow this forever for the life of the app process.
const _maxEntries = 300;
final _cache = <String, _Entry>{};

class _Entry {
  _Entry(this.label) : cachedAt = DateTime.now();
  final String? label;
  final DateTime cachedAt;
}

/// A failed lookup is cached too (so a point with genuinely no address isn't
/// re-queried on every repeat visit within this window), but only for this
/// long — past it, a null result is treated as expired and retried, rather
/// than blacklisting the point for the rest of the app's process lifetime
/// over what may have been a one-off network blip.
const _missRetryAfter = Duration(seconds: 60);

String _key(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';

void _touch(String key, String? label) {
  _cache.remove(key);
  _cache[key] = _Entry(label);
  while (_cache.length > _maxEntries) {
    _cache.remove(_cache.keys.first);
  }
}

/// A human label for [point] — the cached value if we have one (and, for a
/// cached miss, it's still fresh), else fetches and caches it. Takes the
/// repository directly (not a `ref`) so it works equally from a `WidgetRef`
/// call site and from inside a provider, which only exposes the narrower
/// `Ref`.
Future<String?> reverseGeocodeCached(
    PlacesRepository repo, LatLng point) async {
  final key = _key(point);
  final cached = _cache[key];
  if (cached != null &&
      (cached.label != null ||
          DateTime.now().difference(cached.cachedAt) < _missRetryAfter)) {
    _touch(key, cached.label); // bump recency without changing the value
    return cached.label;
  }
  String? label;
  try {
    final hit = await repo.reverse(point);
    label = hit?.label.isNotEmpty == true ? hit!.label : hit?.address;
  } catch (_) {
    label = null;
  }
  _touch(key, label);
  return label;
}
