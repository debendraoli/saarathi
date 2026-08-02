import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_client.dart';
import '../../ride/domain/models.dart';
import '../domain/models.dart';

class DeliveryRepository {
  DeliveryRepository(this._api);

  final ApiClient _api;

  Future<DeliveryEstimate> estimate({
    required LatLng origin,
    required LatLng dest,
    required ParcelSize size,
    bool fragile = false,
  }) async {
    final res = await _api.post('/v1/delivery/estimate', body: {
      'origin': {'lat': origin.latitude, 'lng': origin.longitude},
      'dest': {'lat': dest.latitude, 'lng': dest.longitude},
      'size_tier': size.wire,
      'fragile': fragile,
    });
    return DeliveryEstimate.fromJson(res as Map<String, dynamic>);
  }

  /// Books a parcel; the backend creates a `delivery` trip we can track.
  Future<Trip> book(ParcelDraft draft) async {
    final res = await _api.post('/v1/delivery/parcels', body: draft.bookBody());
    return Trip.fromJson(res as Map<String, dynamic>);
  }
}

final deliveryRepositoryProvider = Provider<DeliveryRepository>((ref) {
  return DeliveryRepository(ref.watch(apiClientProvider));
});
