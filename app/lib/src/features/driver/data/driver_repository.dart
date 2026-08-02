import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_client.dart';
import '../domain/models.dart';

class DriverRepository {
  DriverRepository(this._api);

  final ApiClient _api;

  Future<void> goOnline(LatLng at, List<String> jobTypes) => _api.post(
        '/v1/driver/online',
        body: {'lat': at.latitude, 'lng': at.longitude, 'job_types': jobTypes},
      );

  Future<void> heartbeat(LatLng at, List<String> jobTypes) => _api.post(
        '/v1/driver/heartbeat',
        body: {'lat': at.latitude, 'lng': at.longitude, 'job_types': jobTypes},
      );

  Future<void> goOffline() => _api.post('/v1/driver/offline');

  Future<List<DriverOffer>> offers() async {
    final res = await _api.get('/v1/driver/offers');
    final list = (res as List).cast<Map<String, dynamic>>();
    return list.map(DriverOffer.fromJson).toList();
  }

  Future<void> accept(String tripId) =>
      _api.post('/v1/rides/$tripId/offer/accept');

  Future<void> decline(String tripId) =>
      _api.post('/v1/rides/$tripId/offer/decline');
}

final driverRepositoryProvider = Provider<DriverRepository>((ref) {
  return DriverRepository(ref.watch(apiClientProvider));
});
