import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../../../shared/provider_retry.dart';

class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.label,
    required this.point,
    this.address,
  });

  final String id;
  final String label;
  final LatLng point;
  final String? address;

  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
        id: j['id'] as String,
        label: (j['label'] as String?) ?? '',
        address: j['address'] as String?,
        point: LatLng(
          (j['lat'] as num).toDouble(),
          (j['lng'] as num).toDouble(),
        ),
      );
}

/// A geocoder hit or a stored recent search — a label + address + coordinates.
class PlaceHit {
  const PlaceHit({
    required this.label,
    required this.point,
    this.address = '',
  });

  final String label;
  final String address;
  final LatLng point;

  factory PlaceHit.fromGeo(Map<String, dynamic> j) => PlaceHit(
        label: (j['label'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        point: LatLng(
          (j['lat'] as num).toDouble(),
          (j['lng'] as num).toDouble(),
        ),
      );

  factory PlaceHit.fromRecent(Map<String, dynamic> j) => PlaceHit(
        label: (j['label'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        point: LatLng(
          (j['lat'] as num?)?.toDouble() ?? 0,
          (j['lng'] as num?)?.toDouble() ?? 0,
        ),
      );
}

class PlacesRepository {
  PlacesRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;

  Future<List<SavedPlace>> list() => cacheThroughList(
        prefs: _prefs,
        key: 'cache.places',
        fetch: () => _api.get('/v1/me/locations'),
        parse: SavedPlace.fromJson,
      );

  Future<SavedPlace> add(String label, LatLng point, {String? address}) async {
    final res = await _api.post(
      '/v1/me/locations',
      body: {
        'label': label,
        'address': address,
        'lat': point.latitude,
        'lng': point.longitude,
      },
    ) as Map<String, dynamic>;
    return SavedPlace.fromJson(res);
  }

  Future<void> remove(String id) => _api.delete('/v1/me/locations/$id');

  /// Address autocomplete, biased toward [near] when provided.
  Future<List<PlaceHit>> search(String query,
      {LatLng? near, CancelToken? cancelToken}) async {
    if (query.trim().length < 2) return const [];
    final res = await _api.get(
      '/v1/geo/search',
      query: {
        'q': query.trim(),
        if (near != null) 'lat': near.latitude,
        if (near != null) 'lng': near.longitude,
      },
      cancelToken: cancelToken,
    ) as List;
    return res.cast<Map<String, dynamic>>().map(PlaceHit.fromGeo).toList();
  }

  /// Reverse-geocode a coordinate into a human label (for "Your location").
  Future<PlaceHit?> reverse(LatLng point) async {
    final res = await _api.get('/v1/geo/reverse', query: {
      'lat': point.latitude,
      'lng': point.longitude,
    });
    if (res is Map<String, dynamic>) return PlaceHit.fromGeo(res);
    return null;
  }

  Future<List<PlaceHit>> recentSearches() async {
    final res = await _api.get('/v1/me/recent-searches') as List;
    return res.cast<Map<String, dynamic>>().map(PlaceHit.fromRecent).toList();
  }

  Future<void> addRecent(PlaceHit hit) async {
    await _api.post('/v1/me/recent-searches', body: {
      'label': hit.label,
      'address': hit.address,
      'lat': hit.point.latitude,
      'lng': hit.point.longitude,
    });
  }
}

final placesRepositoryProvider = Provider<PlacesRepository>((ref) {
  return PlacesRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

final savedPlacesProvider = FutureProvider.autoDispose<List<SavedPlace>>((ref) {
  return ref.watch(placesRepositoryProvider).list();
}, retry: shortNetworkRetry);

final recentSearchesProvider =
    FutureProvider.autoDispose<List<PlaceHit>>((ref) {
  return ref.watch(placesRepositoryProvider).recentSearches();
}, retry: shortNetworkRetry);
