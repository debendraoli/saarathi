import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../domain/models.dart';

class RideRepository {
  RideRepository(this._api, this._prefs);

  final ApiClient _api;
  final SharedPreferences _prefs;

  Future<FareEstimate> estimate(RideDraft draft) async {
    final res = await _api.post(
      '/v1/rides/estimate',
      body: {
        'origin': draft.pickup.toJson(),
        'dest': draft.destination.toJson(),
        'vehicle_class': draft.vehicleClass.wire,
      },
    );
    return FareEstimate.fromJson(res as Map<String, dynamic>);
  }

  Future<Trip> book(RideDraft draft) async {
    final res = await _api.post(
      '/v1/rides',
      body: {
        'origin': draft.pickup.toJson(),
        'dest': draft.destination.toJson(),
        'vehicle_class': draft.vehicleClass.wire,
        'payment_method': draft.paymentMethod,
      },
    );
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  Future<Trip> trip(String id) async {
    final res = await _api.get('/v1/rides/$id');
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  Future<List<Trip>> myTrips() => cacheThroughList(
        prefs: _prefs,
        key: 'cache.rides.mytrips',
        fetch: () => _api.get('/v1/rides'),
        parse: Trip.fromJson,
      );

  Future<void> cancel(String id) =>
      _api.post('/v1/rides/$id/status', body: {'status': 'cancelled'});

  /// Driver advances the trip: arriving → in_progress → completed.
  Future<void> updateStatus(String id, String status) =>
      _api.post('/v1/rides/$id/status', body: {'status': status});

  /// Driver publishes live position during an active trip (fanned out over WS).
  Future<void> postLocation(String id, double lat, double lng) =>
      _api.post('/v1/rides/$id/location', body: {'lat': lat, 'lng': lng});

  Future<void> rate(String id, int stars, {String? comment}) => _api.post(
        '/v1/rides/$id/rate',
        body: {
          'stars': stars,
          if (comment != null && comment.isNotEmpty) 'comment': comment
        },
      );

  Future<void> sos(String id, {double? lat, double? lng, String? note}) =>
      _api.post(
        '/v1/rides/$id/sos',
        body: {'lat': lat, 'lng': lng, if (note != null) 'note': note},
      );
}

final rideRepositoryProvider = Provider<RideRepository>((ref) {
  return RideRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});
