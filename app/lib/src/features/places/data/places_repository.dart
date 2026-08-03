import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';

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
}

final placesRepositoryProvider = Provider<PlacesRepository>((ref) {
  return PlacesRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

final savedPlacesProvider = FutureProvider.autoDispose<List<SavedPlace>>((ref) {
  return ref.watch(placesRepositoryProvider).list();
});
