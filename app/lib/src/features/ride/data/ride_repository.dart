import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/models.dart';

class RideRepository {
  RideRepository(this._api);

  final ApiClient _api;

  Future<FareEstimate> estimate(RideDraft draft) async {
    final res = await _api.post('/v1/rides/estimate', body: {
      'origin': draft.pickup.toJson(),
      'dest': draft.destination.toJson(),
      'vehicle_class': draft.vehicleClass.wire,
    });
    return FareEstimate.fromJson(res as Map<String, dynamic>);
  }

  Future<Trip> book(RideDraft draft) async {
    final res = await _api.post('/v1/rides', body: {
      'origin': draft.pickup.toJson(),
      'dest': draft.destination.toJson(),
      'vehicle_class': draft.vehicleClass.wire,
      'payment_method': draft.paymentMethod,
    });
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  Future<Trip> trip(String id) async {
    final res = await _api.get('/v1/rides/$id');
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  Future<void> cancel(String id) => _api.post('/v1/rides/$id/status', body: {'status': 'cancelled'});
}

final rideRepositoryProvider = Provider<RideRepository>((ref) {
  return RideRepository(ref.watch(apiClientProvider));
});
